import SwiftUI
import WebKit
import Observation
import UIKit

struct ClaudeOrganization: Identifiable, Equatable, Codable {
    let id: String
    let name: String
}

@MainActor @Observable
final class ClaudeWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var address = "claude.ai"
    private(set) var loading = false
    private(set) var emailLoginNotice: String?
    /// Google refuses OAuth inside embedded browsers and renders a blank page instead.
    var blockedLoginHost: String? { address == "accounts.google.com" ? address : nil }
    private(set) var organizations: [ClaudeOrganization] = []
    private(set) var selectedOrganizationID: String?
    @ObservationIgnored private static let organizationKey = "claudeSelectedOrganizationID"
    @ObservationIgnored private static let organizationsKey = "claudeOrganizations"
    @ObservationIgnored private let nativeClient = ClaudeQuotaClient()
    @ObservationIgnored private var waitingForLoad: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var quotaNavigationID: UUID?
    @ObservationIgnored private var quotaNavigation: WKNavigation?
    @ObservationIgnored private var quotaRead: (id: UUID, continuation: CheckedContinuation<Any?, Error>)?
    @ObservationIgnored private var quotaReadTimeout: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetchID: UUID?
    @ObservationIgnored private var clearing = false
    @ObservationIgnored private var pendingEmail: String?
    @ObservationIgnored private var emailLoginTask: Task<Void, Never>?
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
        if let data = UserDefaults.standard.data(forKey: Self.organizationsKey),
           let cached = try? JSONDecoder().decode([ClaudeOrganization].self, from: data) {
            organizations = cached.filter { UUID(uuidString: $0.id) != nil }
        }
        super.init()
    }

    func openLogin(email: String? = nil) {
        guard !clearing else { return }
        cancelEmailLogin()
        emailLoginNotice = nil
        pendingEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    func cancelEmailLogin() {
        emailLoginTask?.cancel()
        emailLoginTask = nil
        pendingEmail = nil
    }

    static let emailLoginScript = """
    if (location.origin !== 'https://claude.ai') return 'manual';
    const input = document.querySelector('input[type="email"]');
    if (!input) return 'waiting';
    const form = input.closest('form');
    if (!form || input.disabled || input.readOnly ||
        new URL(form.action, location.href).origin !== location.origin ||
        form.querySelector('input[type="password"], input[type="checkbox"], input[type="radio"], input[autocomplete="one-time-code"]'))
      return 'manual';
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, email);
    input.dispatchEvent(new Event('input', {bubbles:true}));
    input.dispatchEvent(new Event('change', {bubbles:true}));
    await new Promise(resolve => setTimeout(resolve, 100));
    if (!input.isConnected || input.value !== email || !form.checkValidity()) return 'manual';
    const submit = form.querySelector('button[type="submit"], input[type="submit"], button:not([type])');
    if (!submit || submit.disabled) return 'manual';
    form.requestSubmit(submit);
    return 'submitted';
    """

    private func fillLoginEmail() {
        guard let email = pendingEmail, !email.isEmpty, isClaudeOrigin else { return }
        // Consume once before submitting: navigation must never trigger a second email.
        pendingEmail = nil
        emailLoginTask = Task { [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    let result = try await self.webView.callAsyncJavaScript(
                        Self.emailLoginScript, arguments: ["email": email], in: nil, contentWorld: .page
                    ) as? String
                    try Task.checkCancellation()
                    if result == "submitted" {
                        self.emailLoginNotice = String(localized: "Correo completado. Introduce en claude.ai el código que te envíe Claude.")
                        return
                    }
                    guard result == "waiting" else { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
            self.emailLoginNotice = String(localized: "Si el correo no aparece, complétalo directamente en claude.ai. Pulso no acepta permisos ni introduce códigos.")
        }
    }

    static func isAuthoritativeUsageFailure(_ error: Error) -> Bool {
        if let error = error as? ClaudeQuotaError {
            switch error {
            case .signIn, .invalidResponse: return true
            case .cloudflare, .http: return false
            }
        }
        guard let error = error as? ClaudeSessionError else { return false }
        switch error {
        case .signIn, .unsupported, .organization: return true
        case .unavailable: return false
        }
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
        guard fetchID == nil, !clearing else { throw ClaudeSessionError.unavailable }
        let id = UUID()
        fetchID = id
        defer { if fetchID == id { fetchID = nil } }
        let currentGeneration = generation
        let native: ClaudeWebCredentials?
        do { native = try ClaudeCredentialVault.shared.load() }
        catch {
            guard UIApplication.shared.applicationState == .active else { throw error }
            native = nil
        }
        if let native, native.organizationID == selectedOrganizationID {
            UserDefaults.standard.set(Date(), forKey: "claudeNativeLastAttempt")
            UserDefaults.standard.set("En curso", forKey: "claudeNativeLastResult")
            do {
                let reading = try await nativeClient.fetch(native)
                try validateGeneration(currentGeneration)
                try ClaudeCredentialVault.shared.replace(reading.credentials, matching: native)
                UserDefaults.standard.set("Actualizado", forKey: "claudeNativeLastResult")
                return reading.snapshot
            } catch is CancellationError { throw CancellationError() }
            catch {
                let failure = error as NSError
                UserDefaults.standard.set("Error \(failure.domain) (\(failure.code))", forKey: "claudeNativeLastResult")
                let recoverable = (error as? ClaudeQuotaError).map { [.signIn, .cloudflare].contains($0) } ?? false
                guard recoverable, UIApplication.shared.applicationState == .active else { throw error }
            }
        }
        guard UIApplication.shared.applicationState == .active else { throw ClaudeQuotaError.signIn }
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
        UserDefaults.standard.set(try JSONEncoder().encode(organizations), forKey: Self.organizationsKey)
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
        let snapshot: UsageSnapshot
        do { snapshot = try ClaudeUsageParser.parse(usageData) }
        catch { throw ClaudeSessionError.unsupported }
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        try validateGeneration(currentGeneration)
        let credentials = try ClaudeWebCredentials.capture(cookies: cookies, organizationID: organizationID)
        try ClaudeCredentialVault.shared.save(credentials)
        return snapshot
    }

    private var isClaudeOrigin: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == "claude.ai" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private func validateGeneration(_ expected: Int) throws {
        guard generation == expected, !clearing, !Task.isCancelled else { throw CancellationError() }
    }

    /// JavaScript returns quota JSON only; session export uses WebKit's native cookie store.
    private func read(path: String, organizationsOnly: Bool = false) async throws -> Data {
        guard isClaudeOrigin else { throw ClaudeSessionError.signIn }
        let script = """
        if (location.origin !== 'https://claude.ai') throw new Error('origin');
        const controller = new AbortController();
        const requests = globalThis.__pulsoQuotaRequests ??= {};
        requests[requestID] = controller;
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
        } finally {
          clearTimeout(timer);
          delete requests[requestID];
        }
        """
        let result: Any?
        do {
            result = try await readQuotaJavaScript(script, path: path, organizationsOnly: organizationsOnly)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ClaudeSessionError.unavailable }
        guard let string = result as? String, let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? Int else { throw ClaudeSessionError.unsupported }
        if status == 401 || status == 403 { throw ClaudeSessionError.signIn }
        guard status == 200 else { throw ClaudeSessionError.unavailable }
        guard let payload = object["data"], JSONSerialization.isValidJSONObject(payload) else { throw ClaudeSessionError.unsupported }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func readQuotaJavaScript(_ script: String, path: String, organizationsOnly: Bool) async throws -> Any? {
        guard quotaRead == nil else { throw ClaudeSessionError.unavailable }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: { () async throws -> Any? in
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                beginQuotaRead(script, path: path, organizationsOnly: organizationsOnly, id: id, continuation: continuation)
            }
        }, onCancel: {
            Task { @MainActor in self.finishQuotaRead(id: id, result: .failure(CancellationError()), abort: true) }
        })
    }

    private func beginQuotaRead(_ script: String, path: String, organizationsOnly: Bool, id: UUID,
                               continuation: CheckedContinuation<Any?, Error>) {
        quotaRead = (id, continuation)
        // Unlike a JavaScript timer, this also fires when WebKit stops running page scripts.
        quotaReadTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finishQuotaRead(id: id, result: .failure(ClaudeSessionError.unavailable), abort: true)
        }
        let arguments: [String: Any] = ["path": path, "organizationsOnly": organizationsOnly, "requestID": id.uuidString]
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page,
                                   completionHandler: { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let value): self?.finishQuotaRead(id: id, result: .success(value))
                case .failure(let error): self?.finishQuotaRead(id: id, result: .failure(error))
                }
            }
        })
    }

    private func finishQuotaRead(id: UUID, result: Result<Any?, Error>, abort: Bool = false) {
        guard let pending = quotaRead, pending.id == id else { return }
        quotaRead = nil
        quotaReadTimeout?.cancel()
        quotaReadTimeout = nil
        if abort {
            webView.evaluateJavaScript("globalThis.__pulsoQuotaRequests?.['\(id.uuidString)']?.abort();", completionHandler: nil)
        }
        pending.continuation.resume(with: result)
    }

    private func loadUsagePage() async throws {
        guard waitingForLoad == nil else { throw ClaudeSessionError.unavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                quotaNavigationID = id
                waitingForLoad = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.cancelQuotaNavigation(id: id, error: ClaudeSessionError.unavailable)
                }
                cancelEmailLogin()
                emailLoginNotice = nil
                quotaNavigation = webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
            }
        } onCancel: {
            Task { @MainActor in self.cancelQuotaNavigation(id: id, error: CancellationError()) }
        }
    }

    private func cancelQuotaNavigation(id: UUID, error: Error) {
        guard quotaNavigationID == id else { return }
        finishLoad(.failure(error))
        webView.stopLoading()
    }

    func cancelQuotaFetch() {
        guard fetchID != nil else { return }
        generation += 1
        fetchID = nil
        if let quotaNavigationID { cancelQuotaNavigation(id: quotaNavigationID, error: CancellationError()) }
        if let quotaRead { finishQuotaRead(id: quotaRead.id, result: .failure(CancellationError()), abort: true) }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waitingForLoad
        waitingForLoad = nil
        quotaNavigationID = nil
        quotaNavigation = nil
        pending?.resume(with: result)
    }

    func clearSession() async {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }
        cancelEmailLogin()
        emailLoginNotice = nil
        generation += 1
        finishLoad(.failure(CancellationError()))
        if let quotaRead { finishQuotaRead(id: quotaRead.id, result: .failure(CancellationError()), abort: true) }
        organizations = []
        selectedOrganizationID = nil
        UserDefaults.standard.removeObject(forKey: Self.organizationKey)
        UserDefaults.standard.removeObject(forKey: Self.organizationsKey)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emailLoginTask?.cancel()
        loading = true
        address = webView.url?.host ?? "claude.ai"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.host ?? "claude.ai"
        if quotaNavigation === navigation { finishLoad(.success(())) }
        fillLoginEmail()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if quotaNavigation === navigation { finishLoad(.failure(ClaudeSessionError.unavailable)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if quotaNavigation === navigation { finishLoad(.failure(ClaudeSessionError.unavailable)) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoad(.failure(ClaudeSessionError.unavailable))
        if let quotaRead { finishQuotaRead(id: quotaRead.id, result: .failure(ClaudeSessionError.unavailable)) }
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
        case .signIn: return String(localized: "Abre la sesión de Claude y vuelve a consultar. El inicio de sesión puede no admitir navegadores integrados.")
        case .unsupported: return String(localized: "Claude ha devuelto un formato de cuota no compatible. Abre su panel web para consultar el uso.")
        case .unavailable: return String(localized: "No se ha podido consultar Claude. Comprueba la conexión o abre su panel web.")
        case .organization: return String(localized: "Selecciona una organización de Claude y vuelve a consultar.")
        }
    }
}

struct ClaudeBrowser: UIViewRepresentable {
    let session: ClaudeWebSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
