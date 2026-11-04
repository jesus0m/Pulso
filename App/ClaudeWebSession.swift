import SwiftUI
import WebKit
import Observation

struct ClaudeOrganization: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor @Observable
final class ClaudeWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var address = "claude.ai"
    private(set) var loading = false
    private(set) var organizations: [ClaudeOrganization] = []
    private(set) var selectedOrganizationID: String?
    @ObservationIgnored private static let organizationKey = "claudeSelectedOrganizationID"
    @ObservationIgnored private var waitingForLoad: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var clearing = false
    @ObservationIgnored lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Dedicated, stable persistent store. Claude logout never touches Codex's default store.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6B242E4D-12D7-45EB-A21E-7624D8275E24")!)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    override init() {
        selectedOrganizationID = UserDefaults.standard.string(forKey: Self.organizationKey)
        super.init()
    }

    func openLogin() {
        guard !clearing else { return }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    func selectOrganization(_ id: String) throws {
        guard organizations.contains(where: { $0.id == id }) else { throw ClaudeSessionError.organization }
        guard selectedOrganizationID != id else { return }
        generation += 1
        finishLoad(.failure(CancellationError()))
        selectedOrganizationID = id
        UserDefaults.standard.set(id, forKey: Self.organizationKey)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard !fetching, !clearing else { throw ClaudeSessionError.unavailable }
        fetching = true
        defer { fetching = false }
        let currentGeneration = generation
        if !isClaudeOrigin || webView.isLoading { try await loadUsagePage() }
        try validateGeneration(currentGeneration)
        guard isClaudeOrigin else { throw ClaudeSessionError.signIn }

        let organizationData = try await read(path: "/api/organizations", organizationsOnly: true)
        try validateGeneration(currentGeneration)
        struct OrganizationPayload: Decodable { let uuid: String; let name: String }
        guard let raw = try? JSONDecoder().decode([OrganizationPayload].self, from: organizationData),
              !raw.isEmpty, raw.allSatisfy({ UUID(uuidString: $0.uuid) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(raw.map(\.uuid)).count == raw.count else { throw ClaudeSessionError.unsupported }
        organizations = raw.map { ClaudeOrganization(id: $0.uuid, name: $0.name) }
        if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
            selectedOrganizationID = nil
            UserDefaults.standard.removeObject(forKey: Self.organizationKey)
        }
        if organizations.count == 1, selectedOrganizationID == nil {
            selectedOrganizationID = organizations[0].id
            UserDefaults.standard.set(selectedOrganizationID, forKey: Self.organizationKey)
        }
        guard let organizationID = selectedOrganizationID else { throw ClaudeSessionError.organization }
        // UUID validation above limits the path component; JS also URI-encodes it.
        let usageData = try await read(path: "/api/organizations/\(organizationID)/usage")
        try validateGeneration(currentGeneration)
        do { return try ClaudeUsageParser.parse(usageData) }
        catch { throw ClaudeSessionError.unsupported }
    }

    private var isClaudeOrigin: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == "claude.ai" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private func validateGeneration(_ expected: Int) throws {
        guard generation == expected, !clearing, !Task.isCancelled else { throw CancellationError() }
    }

    /// Only usage JSON or validated public organization IDs/names cross the WebKit boundary.
    private func read(path: String, organizationsOnly: Bool = false) async throws -> Data {
        guard isClaudeOrigin else { throw ClaudeSessionError.signIn }
        let script = """
        if (location.origin !== 'https://claude.ai') throw new Error('origin');
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const safePath = path.split('/').map(encodeURIComponent).join('/');
          const response = await fetch(safePath, {credentials:'include', redirect:'error', signal:controller.signal});
          if (!response.ok) return JSON.stringify({status:response.status});
          const payload = await response.json();
          if (organizationsOnly) {
            if (!Array.isArray(payload)) return JSON.stringify({status:200});
            return JSON.stringify({status:200, data:payload.map(item => ({uuid:item.uuid, name:item.name}))});
          }
          return JSON.stringify({status:200, data:payload});
        } finally { clearTimeout(timer); }
        """
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(script, arguments: ["path": path, "organizationsOnly": organizationsOnly], in: nil, contentWorld: .page)
        } catch { throw ClaudeSessionError.unavailable }
        guard let string = result as? String, let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? Int else { throw ClaudeSessionError.unsupported }
        if status == 401 || status == 403 { throw ClaudeSessionError.signIn }
        guard status == 200 else { throw ClaudeSessionError.unavailable }
        guard let payload = object["data"], JSONSerialization.isValidJSONObject(payload) else { throw ClaudeSessionError.unsupported }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func loadUsagePage() async throws {
        guard waitingForLoad == nil else { throw ClaudeSessionError.unavailable }
        try await withCheckedThrowingContinuation { continuation in
            waitingForLoad = continuation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finishLoad(.failure(ClaudeSessionError.unavailable))
            }
            openLogin()
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waitingForLoad
        waitingForLoad = nil
        pending?.resume(with: result)
    }

    func clearSession() async {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }
        generation += 1
        finishLoad(.failure(CancellationError()))
        organizations = []
        selectedOrganizationID = nil
        UserDefaults.standard.removeObject(forKey: Self.organizationKey)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        address = webView.url?.host ?? "claude.ai"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.host ?? "claude.ai"
        finishLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        finishLoad(.failure(ClaudeSessionError.unavailable))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        finishLoad(.failure(ClaudeSessionError.unavailable))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private enum ClaudeSessionError: LocalizedError {
    case signIn, unsupported, unavailable, organization
    var errorDescription: String? {
        switch self {
        case .signIn: return "Abre la sesión de Claude y vuelve a consultar. El inicio de sesión puede no admitir navegadores integrados."
        case .unsupported: return "Claude ha devuelto un formato de cuota no compatible. Abre su panel web para consultar el uso."
        case .unavailable: return "No se ha podido consultar Claude. Comprueba la conexión o abre su panel web."
        case .organization: return "Selecciona una organización de Claude y vuelve a consultar."
        }
    }
}

struct ClaudeBrowser: UIViewRepresentable {
    let session: ClaudeWebSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
