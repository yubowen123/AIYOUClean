import Foundation
import CryptoKit
import Security
import AuthenticationServices
import AppKit

public struct ConnectedOAuthRequest: Sendable {
    public let configuration: ConnectedConfiguration
    public let verifier: String
    public let state: String
    public let challenge: String
    public let createdAt: Date
    public init(configuration: ConnectedConfiguration, verifier: String? = nil, state: String? = nil, createdAt: Date = Date()) throws {
        guard configuration.validationIssue == nil else { throw configuration.clientID.isEmpty ? ConnectedError.unconfigured : ConnectedError.invalidConfiguration }
        if configuration.isGoogleLoopback, (URLComponents(string: configuration.redirectURI)?.port ?? 0) == 0 { throw ConnectedError.invalidConfiguration }
        self.configuration = configuration
        let v = try verifier ?? Self.randomURLSafe(bytes: 32)
        guard (43...128).contains(v.count), v.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~").contains($0) }) else { throw ConnectedError.invalidConfiguration }
        self.verifier = v; self.challenge = Self.challenge(for: v)
        self.state = try state ?? Self.randomURLSafe(bytes: 32)
        guard self.state.count >= 32 else { throw ConnectedError.invalidConfiguration }
        self.createdAt = createdAt
    }
    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func randomURLSafe(bytes: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else { throw ConnectedError.randomFailure }
        return base64URL(Data(buffer))
    }
    public var authorizationURL: URL {
        let c = configuration
        let endpoint: String
        switch c.provider.serviceFamily {
        case "google": endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        case "microsoft": endpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        default: endpoint = "https://www.dropbox.com/oauth2/authorize"
        }
        var components = URLComponents(string: endpoint)!
        var query: [URLQueryItem] = [
            .init(name: "client_id", value: c.clientID), .init(name: "redirect_uri", value: c.redirectURI), .init(name: "response_type", value: "code"),
            .init(name: "scope", value: c.scopes.joined(separator: " ")), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
        ]
        if c.provider.serviceFamily == "microsoft" { query.append(.init(name: "response_mode", value: "query")) }
        if c.persistentConnection && c.provider.serviceFamily == "google" { query.append(.init(name: "access_type", value: "offline")); query.append(.init(name: "prompt", value: "consent")) }
        if c.provider == .dropbox { query.append(.init(name: "token_access_type", value: c.persistentConnection ? "offline" : "online")) }
        components.queryItems = query
        return components.url!
    }
    public func validatedCode(from callback: URL, now: Date = Date()) throws -> String {
        guard callback.absoluteString.utf8.count <= 32768 else { throw ConnectedError.invalidCallback }
        guard now.timeIntervalSince(createdAt) >= -30, now.timeIntervalSince(createdAt) <= 600 else { throw ConnectedError.expiredAuthorization }
        guard let expected = URLComponents(string: configuration.redirectURI), let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              actual.scheme?.lowercased() == expected.scheme?.lowercased(), actual.host?.lowercased() == expected.host?.lowercased(), actual.port == expected.port,
              actual.percentEncodedPath == expected.percentEncodedPath, actual.user == nil, actual.password == nil, actual.fragment == nil else { throw ConnectedError.invalidCallback }
        let query = actual.queryItems ?? []
        let sensitive = Set(["access_token", "refresh_token", "id_token", "token_type"])
        guard !query.contains(where: { sensitive.contains($0.name.lowercased()) }) else { throw ConnectedError.invalidCallback }
        var values: [String: String] = [:]
        for item in query {
            guard values[item.name] == nil, let value = item.value, value.count <= 16384 else { throw ConnectedError.invalidCallback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw ConnectedError.stateMismatch }
        if values["error"] != nil { throw ConnectedError.authorizationDenied }
        guard let code = values["code"], !code.isEmpty, !code.contains(where: { $0.isNewline }) else { throw ConnectedError.invalidCallback }
        return code
    }
    public func tokenRequest(code: String) -> URLRequest {
        Self.formRequest(configuration: configuration, fields: ["grant_type": "authorization_code", "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI, "code": code, "code_verifier": verifier])
    }
    static func formRequest(configuration: ConnectedConfiguration, fields: [String: String]) -> URLRequest {
        let endpoint: String
        switch configuration.provider.serviceFamily {
        case "google": endpoint = "https://oauth2.googleapis.com/token"
        case "microsoft": endpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        default: endpoint = "https://api.dropboxapi.com/oauth2/token"
        }
        var request = URLRequest(url: URL(string: endpoint)!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map { ConnectedURL.form($0.key) + "=" + ConnectedURL.form($0.value) }.joined(separator: "&").utf8)
        return request
    }
}

enum ConnectedURL {
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func form(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved)! }
    static func path(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= 4096, !text.contains(where: { $0.isNewline }), text != ".", text != ".." else { throw ConnectedError.invalidResponse }
        return form(text)
    }
    static func validate(_ url: URL, provider: ConnectedProvider) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.fragment == nil,
              !(c.queryItems ?? []).contains(where: { ["access_token", "refresh_token", "code", "client_secret"].contains($0.name.lowercased()) }) else { throw ConnectedError.unsafeURL }
        let host = c.host?.lowercased() ?? ""
        let accepted: Bool
        switch provider {
        case .googleDrive: accepted = host == "www.googleapis.com" && c.path.hasPrefix("/drive/v3/files")
        case .gmail: accepted = host == "gmail.googleapis.com" && c.path.hasPrefix("/gmail/v1/users/me/messages")
        case .oneDrive: accepted = host == "graph.microsoft.com" && c.path.hasPrefix("/v1.0/me/drive/")
        case .outlook: accepted = host == "graph.microsoft.com" && (c.path.hasPrefix("/v1.0/me/mailFolders/inbox/messages") || c.path.hasPrefix("/v1.0/me/messages/"))
        case .dropbox: accepted = host == "api.dropboxapi.com" && ["/2/files/list_folder", "/2/files/list_folder/continue", "/2/files/delete_v2"].contains(c.path)
        }
        guard accepted else { throw ConnectedError.unsafeURL }
    }
}

public final class ConnectedKeychainStore: ConnectedTokenStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "local.aiyou.AIYOUClean.connected") { self.service = service }
    private func query(_ key: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false] }
    public func read(key: String) throws -> ConnectedToken? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ConnectedError.keychain(status) }
        guard let data = result as? Data, let token = try? JSONDecoder().decode(ConnectedToken.self, from: data) else { throw ConnectedError.invalidResponse }
        return token
    }
    public func write(_ token: ConnectedToken, key: String) throws {
        let data = try JSONEncoder().encode(token)
        let attrs = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil); guard added == errSecSuccess else { throw ConnectedError.keychain(added) }
        } else if status != errSecSuccess { throw ConnectedError.keychain(status) }
    }
    public func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectedError.keychain(status) }
    }
}

private actor ConnectedNetworkBudget {
    static let shared = ConnectedNetworkBudget()
    private var active = 0
    func acquire() async throws {
        while active >= 2 { try await Task.sleep(nanoseconds: 25_000_000); try Task.checkCancellation() }
        try Task.checkCancellation(); active += 1
    }
    func release() { active = max(0, active - 1) }
}
private final class ConnectedRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func install(_ task: URLSessionDataTask) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel(); task.resume() } else { task.resume() }
    }
    func cancel() { lock.lock(); cancelled = true; let current = task; lock.unlock(); current?.cancel() }
}
private final class ConnectedBoundedDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Delegate callbacks use a dedicated serial queue. No complete response can exceed 2 MiB.
    private var continuation: CheckedContinuation<ConnectedHTTPResult, Error>?
    private var buffer = Data()
    private var status = 0
    private var failure: ConnectedError?
    private let limit = 2_097_152
    init(_ continuation: CheckedContinuation<ConnectedHTTPResult, Error>) { self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { failure = .invalidResponse; completionHandler(.cancel); return }
        guard response.expectedContentLength <= Int64(limit) else { failure = .invalidResponse; completionHandler(.cancel); return }
        status = response.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= limit - buffer.count else { failure = .invalidResponse; buffer.removeAll(keepingCapacity: false); dataTask.cancel(); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let failure { continuation.resume(throwing: failure) }
        else if let error = error as NSError? { continuation.resume(throwing: error.code == NSURLErrorCancelled ? ConnectedError.cancelled : ConnectedError.network) }
        else { continuation.resume(returning: ConnectedHTTPResult(status: status, data: buffer)) }
        buffer.removeAll(keepingCapacity: false); session.finishTasksAndInvalidate()
    }
}
public final class ConnectedURLSessionTransport: ConnectedTransport, @unchecked Sendable {
    public init() {}
    public func send(_ request: URLRequest) async throws -> ConnectedHTTPResult {
        let permitted = Set(["oauth2.googleapis.com", "www.googleapis.com", "gmail.googleapis.com", "login.microsoftonline.com", "graph.microsoft.com", "api.dropboxapi.com"])
        guard let url = request.url, url.scheme == "https", permitted.contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw ConnectedError.unsafeURL }
        try await ConnectedNetworkBudget.shared.acquire()
        let handle = ConnectedRequestHandle()
        do {
            let result: ConnectedHTTPResult = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let config = URLSessionConfiguration.ephemeral
                    config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60; config.httpMaximumConnectionsPerHost = 2
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
                    let session = URLSession(configuration: config, delegate: ConnectedBoundedDelegate(continuation), delegateQueue: queue)
                    handle.install(session.dataTask(with: request))
                }
            }, onCancel: { handle.cancel() })
            await ConnectedNetworkBudget.shared.release(); return result
        } catch {
            await ConnectedNetworkBudget.shared.release()
            if let error = error as? ConnectedError { throw error }
            throw ConnectedError.network
        }
    }
}

private final class ConnectedWebSessionReference: @unchecked Sendable {
    @MainActor weak var value: ConnectedOAuthWebSession?
    @MainActor init(_ value: ConnectedOAuthWebSession) { self.value = value }
}
/// The system sheet owns credential entry. Google Desktop may complete through a one-shot IPv4 loopback listener.
@MainActor
public final class ConnectedOAuthWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private weak var anchor: NSWindow?
    private var loopback: ConnectedLoopbackListener?
    private var callbackTask: Task<Void, Never>?
    public override init() { super.init() }
    public func authenticate(_ request: ConnectedOAuthRequest, loopback: ConnectedLoopbackListener? = nil, anchor: NSWindow? = nil) async throws -> URL {
        guard session == nil, request.configuration.isGoogleLoopback == (loopback != nil) else { throw ConnectedError.invalidConfiguration }
        self.anchor = anchor ?? NSApp.keyWindow
        guard self.anchor != nil else { throw ConnectedError.invalidConfiguration }
        self.loopback = loopback
        let receiver = ConnectedWebSessionReference(self)
        let scheme = loopback == nil ? URL(string: request.configuration.redirectURI)!.scheme : nil
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if let loopback {
                    callbackTask = Task {
                        do {
                            let callback = try await loopback.waitForCallback()
                            receiver.value?.finish(.success(callback))
                        } catch {
                            receiver.value?.finish(.failure((error as? ConnectedError) ?? ConnectedError.network))
                        }
                    }
                }
                let auth = ASWebAuthenticationSession(url: request.authorizationURL, callbackURLScheme: scheme) { url, error in
                    Task { @MainActor in
                        guard let target = receiver.value, target.continuation != nil else { return }
                        if target.loopback != nil {
                            // Only the validated listener result can complete a loopback flow.
                            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { target.finish(.failure(ConnectedError.cancelled)) }
                            else { target.finish(.failure(ConnectedError.authorizationDenied)) }
                        } else if let url { target.finish(.success(url)) }
                        else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { target.finish(.failure(ConnectedError.cancelled)) }
                        else { target.finish(.failure(ConnectedError.authorizationDenied)) }
                    }
                }
                auth.presentationContextProvider = self; auth.prefersEphemeralWebBrowserSession = true
                self.session = auth
                if !auth.start() { self.finish(.failure(ConnectedError.authorizationDenied)) }
            }
        }, onCancel: { Task { @MainActor in receiver.value?.cancel() } })
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        // Clear the continuation before cancelling the system sheet: its cancelled callback is then ignored.
        self.continuation = nil
        let browser = session; session = nil; anchor = nil
        callbackTask?.cancel(); callbackTask = nil
        loopback?.cancel(); loopback = nil
        browser?.cancel()
        continuation.resume(with: result)
    }
    public func cancel() { finish(.failure(ConnectedError.cancelled)) }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? NSApp.keyWindow ?? NSWindow() }
}
