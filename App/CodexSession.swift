import AuthenticationServices
import Darwin
import Network
import Observation
import UIKit

@MainActor @Observable
final class CodexSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var isSigningIn = false
    private(set) var accountLabel: String?
    @ObservationIgnored private let client: CodexOAuthClient
    @ObservationIgnored private let load: () throws -> CodexCredentials?
    @ObservationIgnored private let save: (CodexCredentials) throws -> Void
    @ObservationIgnored private let delete: () throws -> Void
    @ObservationIgnored private let legacyToken: () -> String?
    @ObservationIgnored private var browser: ASWebAuthenticationSession?
    @ObservationIgnored private var browserID: UUID?
    @ObservationIgnored private var loginTask: Task<Void, Error>?
    @ObservationIgnored private var refreshTask: Task<CodexCredentials, Error>?
    @ObservationIgnored private var generation = 0

    init(client: CodexOAuthClient = CodexOAuthClient(),
         load: @escaping () throws -> CodexCredentials? = CodexCredentialVault.load,
         save: @escaping (CodexCredentials) throws -> Void = CodexCredentialVault.save,
         delete: @escaping () throws -> Void = CodexCredentialVault.delete,
         legacyToken: @escaping () -> String? = CodexPastedToken.load) {
        self.client = client
        self.load = load
        self.save = save
        self.delete = delete
        self.legacyToken = legacyToken
        accountLabel = (try? load())?.email
        super.init()
    }

    func signIn() async throws {
        guard !isSigningIn else { throw CancellationError() }
        isSigningIn = true
        let version = generation
        let task = Task { try await self.authenticate(version: version) }
        loginTask = task
        defer {
            loginTask = nil
            isSigningIn = false
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func authenticate(version: Int) async throws {
        let attempt = try CodexOAuth.makeAttempt()
        let callback = try await CodexCallbackServer.start(state: attempt.state)
        defer {
            callback.cancel()
            let finishedBrowser = browser
            browser = nil
            browserID = nil
            finishedBrowser?.cancel()
        }
        try Task.checkCancellation()
        let sessionID = UUID()
        browserID = sessionID
        let session = ASWebAuthenticationSession(
            url: CodexOAuth.authorizationURL(redirect: callback.redirect, attempt: attempt),
            callbackURLScheme: nil
        ) { [weak self] _, _ in
            Task { @MainActor in
                guard self?.browserID == sessionID else { return }
                self?.loginTask?.cancel()
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        browser = session
        guard session.start() else { throw CodexAuthError.browser }
        let url = try await callback.wait()
        let code = try CodexOAuth.authorizationCode(callback: url, redirect: callback.redirect, state: attempt.state)
        let credentials = try await client.exchange(code: code, redirect: callback.redirect, verifier: attempt.verifier)
        try Task.checkCancellation()
        guard version == generation else { throw CancellationError() }
        try save(credentials)
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        accountLabel = credentials.email
    }

    func cancelSignIn() { loginTask?.cancel() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let version = generation
        guard var credentials = try load() else {
            guard let token = legacyToken() else { throw CodexAuthError.signIn }
            let legacy = CodexCredentials(accessToken: token, refreshToken: nil, idToken: nil,
                                          accountID: nil, email: nil, expiresAt: nil)
            let snapshot = try await client.fetchUsage(legacy)
            guard version == generation else { throw CancellationError() }
            return snapshot
        }
        var renewed = false
        if credentials.needsRefresh(at: client.now()), credentials.refreshToken != nil {
            credentials = try await refresh(credentials)
            renewed = true
        }
        let snapshot: UsageSnapshot
        do { snapshot = try await client.fetchUsage(credentials) }
        catch CodexAuthError.signIn where !renewed && credentials.refreshToken != nil {
            credentials = try await refresh(credentials)
            snapshot = try await client.fetchUsage(credentials)
        }
        guard version == generation else { throw CancellationError() }
        accountLabel = credentials.email
        return snapshot
    }

    private func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        if let refreshTask { return try await refreshTask.value }
        let version = generation
        let task = Task {
            try await SharedQuotaAccess.withOAuthLock {
                guard let current = try load(), version == generation else { throw CancellationError() }
                if current != credentials { return current }
                let updated = try await client.refresh(current)
                try Task.checkCancellation()
                try SharedQuotaAccess.transaction {
                    guard version == generation, try load() == current else { throw CancellationError() }
                    try save(updated)
                }
                return updated
            }
        }
        refreshTask = task
        defer { if version == generation { refreshTask = nil } }
        return try await task.value
    }

    func clearSession() throws {
        generation += 1
        loginTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        try delete()
        try CodexPastedToken.delete()
        accountLabel = nil
    }
}

@MainActor
final class CodexCallbackServer {
    private(set) var redirect: URL
    private let state: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.jesusom.pulso.codex-callback")
    private var ready: CheckedContinuation<Void, Error>?
    private var waiting: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    private init(port: UInt16, state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: Self.loopbackHost(), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        redirect = URL(string: "http://localhost:\(port)/auth/callback")!
    }

    private static func loopbackHost() -> NWEndpoint.Host {
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", nil, nil, &addresses) == 0, let addresses else { return .ipv4(.loopback) }
        defer { freeaddrinfo(addresses) }
        var current: UnsafeMutablePointer<addrinfo>? = addresses
        while let entry = current {
            if entry.pointee.ai_family == AF_INET6 { return .ipv6(.loopback) }
            if entry.pointee.ai_family == AF_INET { return .ipv4(.loopback) }
            current = entry.pointee.ai_next
        }
        return .ipv4(.loopback)
    }

    static func start(state: String, ports: [UInt16] = [1455, 1457]) async throws -> CodexCallbackServer {
        for port in ports {
            try Task.checkCancellation()
            do {
                let server = try CodexCallbackServer(port: port, state: state)
                do {
                    try await server.startListening()
                    return server
                } catch {
                    server.cancel()
                    try Task.checkCancellation()
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw CodexAuthError.listener
    }

    private func startListening() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection, data: Data(), start: true) }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready:
                    if let port = self.listener.port {
                        self.redirect = URL(string: "http://localhost:\(port.rawValue)/auth/callback")!
                    }
                    self.ready?.resume()
                    self.ready = nil
                case .failed, .cancelled:
                    self.ready?.resume(throwing: CodexAuthError.listener)
                    self.ready = nil
                    self.complete(.failure(CodexAuthError.listener))
                default: break
                }
            }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: { [listener] in listener.cancel() }
    }

    func wait(timeout: Duration = .seconds(180)) async throws -> URL {
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            complete(.failure(CodexAuthError.timeout))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: {
            Task { @MainActor in self.complete(.failure(CancellationError())) }
        }
    }

    func cancel() {
        listener.cancel()
        complete(.failure(CancellationError()))
    }

    private func complete(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value
        waiting?.resume(with: value)
        waiting = nil
    }

    private func receive(_ connection: NWConnection, data: Data, start: Bool = false) {
        if start { connection.start(queue: queue) }
        guard data.count < 8192 else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] chunk, _, ended, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let accumulated = data + (chunk ?? Data())
                if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, request: String(decoding: accumulated, as: UTF8.self))
                } else if ended || error != nil { connection.cancel() }
                else { self.receive(connection, data: accumulated) }
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let first = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        var callback: URL?
        var outcome: Result<URL, Error>?
        if first.count == 3, first[0] == "GET", first[1].hasPrefix("/"),
           let url = URL(string: String(first[1]), relativeTo: redirect)?.absoluteURL {
            do {
                _ = try CodexOAuth.authorizationCode(callback: url, redirect: redirect, state: state)
                callback = url
                outcome = .success(url)
            } catch CodexAuthError.denied { outcome = .failure(CodexAuthError.denied) }
            catch { /* Ignore unrelated or unverifiable requests; keep waiting for the real callback. */ }
        }
        let message = callback != nil ? String(localized: "Listo. Puedes volver a Pulso.") : String(localized: "Solicitud no valida.")
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(callback != nil ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let outcome else { return }
            Task { @MainActor in self?.complete(outcome) }
        })
    }
}
