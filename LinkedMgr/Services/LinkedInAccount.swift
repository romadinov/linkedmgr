import AppKit
import Foundation
import Network
import Observation

/// The connected LinkedIn member and their OAuth token.
///
/// Uses LinkedIn's standard 3-legged OAuth with your own developer app
/// ("Share on LinkedIn" + "Sign In with LinkedIn using OpenID Connect" products).
/// The browser redirects to a one-shot listener on 127.0.0.1, so no server is needed.
@MainActor @Observable
final class LinkedInAccount {
    static let shared = LinkedInAccount()

    static let redirectPort: UInt16 = 8765
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }
    static let scopes = "openid profile w_member_social"

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "clientID") }
    }
    var clientSecret: String {
        didSet { Keychain.set(clientSecret, for: "clientSecret") }
    }
    private(set) var accessToken: String?
    private(set) var tokenExpiresAt: Date?
    private(set) var personURN: String?
    private(set) var memberName: String?
    var isSigningIn = false
    var lastError: String?

    private init() {
        let d = UserDefaults.standard
        clientID = d.string(forKey: "clientID") ?? ""
        clientSecret = Keychain.get("clientSecret") ?? ""
        accessToken = Keychain.get("accessToken")
        tokenExpiresAt = d.object(forKey: "tokenExpiresAt") as? Date
        personURN = d.string(forKey: "personURN")
        memberName = d.string(forKey: "memberName")
    }

    var isConnected: Bool {
        guard accessToken != nil, personURN != nil else { return false }
        return (tokenExpiresAt ?? .distantFuture) > Date()
    }

    /// Member tokens last 60 days and self-serve apps get no refresh token, so warn early.
    var expiresSoon: Bool {
        guard let tokenExpiresAt else { return false }
        return tokenExpiresAt.timeIntervalSinceNow < 7 * 86_400
    }

    /// Reads the credentials fresh from the Keychain and defaults, so the agent picks up a
    /// reconnect made in the app without restarting.
    nonisolated static func currentClient() -> LinkedInClient? {
        let d = UserDefaults.standard
        guard let token = Keychain.get("accessToken"), let personURN = d.string(forKey: "personURN") else { return nil }
        if let exp = d.object(forKey: "tokenExpiresAt") as? Date, exp <= Date() { return nil }
        return LinkedInClient(token: token, personURN: personURN)
    }

    var client: LinkedInClient? {
        guard isConnected, let accessToken, let personURN else { return nil }
        return LinkedInClient(token: accessToken, personURN: personURN)
    }

    func signIn() async {
        lastError = nil
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            lastError = "Enter your LinkedIn app's Client ID and Client Secret first."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let state = UUID().uuidString
            var components = URLComponents(string: "https://www.linkedin.com/oauth/v2/authorization")!
            components.queryItems = [
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: Self.redirectURI),
                .init(name: "state", value: state),
                .init(name: "scope", value: Self.scopes),
            ]
            let receiver = try LoopbackReceiver(port: Self.redirectPort)
            NSWorkspace.shared.open(components.url!)
            let params = try await receiver.waitForCallback()
            if let error = params["error"] {
                throw LinkedInError.message(params["error_description"] ?? error)
            }
            guard params["state"] == state, let code = params["code"] else {
                throw LinkedInError.message("LinkedIn's sign-in response didn't match this request. Try again.")
            }
            let token = try await LinkedInClient.exchangeCode(code, clientID: clientID, clientSecret: clientSecret,
                                                              redirectURI: Self.redirectURI)
            let me = try await LinkedInClient.userInfo(token: token.accessToken)
            store(token: token.accessToken, expiresIn: token.expiresIn, personURN: "urn:li:person:\(me.sub)", name: me.name)
            NSApp.activate()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.set(nil, for: "accessToken")
        accessToken = nil
        tokenExpiresAt = nil
        personURN = nil
        memberName = nil
        let d = UserDefaults.standard
        ["tokenExpiresAt", "personURN", "memberName"].forEach { d.removeObject(forKey: $0) }
    }

    private func store(token: String, expiresIn: Int, personURN: String, name: String?) {
        Keychain.set(token, for: "accessToken")
        accessToken = token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        self.personURN = personURN
        memberName = name
        let d = UserDefaults.standard
        d.set(tokenExpiresAt, forKey: "tokenExpiresAt")
        d.set(personURN, forKey: "personURN")
        d.set(name, forKey: "memberName")
    }
}

/// Accepts exactly one HTTP request on 127.0.0.1 and returns its query parameters.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackReceiver")

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            listener.newConnectionHandler = { [listener, queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    // "GET /callback?code=…&state=… HTTP/1.1"
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard target.hasPrefix("/callback") else {
                        connection.send(content: Self.response(status: "404 Not Found", body: ""),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    var result: [String: String] = [:]
                    URLComponents(string: target)?.queryItems?.forEach { result[$0.name] = $0.value ?? "" }
                    let body = "<html><body style='font:16px -apple-system;padding:40px'>"
                        + "<h2>LinkedMgr is connected.</h2><p>You can close this tab.</p></body></html>"
                    connection.send(content: Self.response(status: "200 OK", body: body),
                                    completion: .contentProcessed { _ in connection.cancel() })
                    listener.cancel()
                    once.resume(.success(result))
                }
            }
            listener.stateUpdateHandler = { [listener] state in
                if case .failed(let error) = state {
                    listener.cancel()
                    once.resume(.failure(LinkedInError.message(
                        "Couldn't listen on port \(LinkedInAccount.redirectPort): \(error.localizedDescription)")))
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [listener] in
                listener.cancel()
                once.resume(.failure(LinkedInError.message("Timed out waiting for LinkedIn sign-in.")))
            }
        }
    }

    private static func response(status: String, body: String) -> Data {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<[String: String], Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<[String: String], Error>) { continuation = c }
        func resume(_ result: Result<[String: String], Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
