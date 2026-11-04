import SwiftUI
import WebKit
import Observation

@MainActor @Observable
final class CodexWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var address = "chatgpt.com"
    private(set) var loading = false
    /// Google refuses OAuth inside embedded browsers and renders a blank page instead.
    var blockedLoginHost: String? { address == "accounts.google.com" ? address : nil }
    private(set) var accountLabel: String?
    @ObservationIgnored private var waitingForLoad: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    func openLogin() {
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/codex/settings/usage")!))
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let currentGeneration = generation
        if webView.url?.host != "chatgpt.com" || webView.isLoading {
            try await loadUsagePage()
        }
        guard generation == currentGeneration else { throw CancellationError() }
        guard webView.url?.scheme == "https", webView.url?.host == "chatgpt.com" else { throw SessionError.signIn }
        // Tokens stay inside the official website's JS context and are never returned to Swift.
        let script = """
        if (location.origin !== 'https://chatgpt.com') throw new Error('origin');
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const sessionResponse = await fetch('/api/auth/session', {credentials:'include', signal:controller.signal});
          if (!sessionResponse.ok) return JSON.stringify({status:sessionResponse.status});
          const session = await sessionResponse.json();
          if (!session.accessToken) return JSON.stringify({status:401});
          const response = await fetch('/backend-api/wham/usage', {
            credentials:'include', signal:controller.signal,
            headers:{Authorization:'Bearer ' + session.accessToken}
          });
          if (!response.ok) return JSON.stringify({status:response.status});
          return JSON.stringify({status:200, data:await response.json(),
            account: typeof session.user?.email === 'string' ? session.user.email : null});
        } finally { clearTimeout(timer); }
        """
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        guard generation == currentGeneration else { throw CancellationError() }
        guard let string = result as? String, let data = string.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? Int else { throw SessionError.unsupported }
        if status == 401 || status == 403 { throw SessionError.signIn }
        guard status == 200, let payload = object["data"] else { throw SessionError.unavailable }
        do {
            let snapshot = try CodexUsageParser.parse(JSONSerialization.data(withJSONObject: payload))
            accountLabel = object["account"] as? String
            return snapshot
        } catch { throw SessionError.unsupported }
    }

    private func loadUsagePage() async throws {
        guard waitingForLoad == nil else { throw SessionError.unavailable }
        try await withCheckedThrowingContinuation { continuation in
            waitingForLoad = continuation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finishLoad(.failure(SessionError.unavailable))
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
        generation += 1
        accountLabel = nil
        finishLoad(.failure(CancellationError()))
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        address = webView.url?.host ?? "chatgpt.com"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.host ?? "chatgpt.com"
        finishLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        finishLoad(.failure(SessionError.unavailable))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        finishLoad(.failure(SessionError.unavailable))
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

private enum SessionError: LocalizedError {
    case signIn, unsupported, unavailable
    var errorDescription: String? {
        switch self {
        case .signIn: return "Abre la sesión de ChatGPT y vuelve a consultar. El inicio de sesión puede no admitir navegadores integrados."
        case .unsupported: return "Codex ha devuelto un formato de cuota no compatible. Abre su panel web para consultar el uso."
        case .unavailable: return "No se ha podido consultar Codex. Comprueba la conexión o abre su panel web."
        }
    }
}

struct CodexBrowser: UIViewRepresentable {
    let session: CodexWebSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
