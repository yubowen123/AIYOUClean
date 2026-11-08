import Foundation
import Darwin
import CleanRoomCore

private enum ConnectedCheckFailure: Error { case failed(String) }
private func expectConnected(_ condition: Bool, _ label: String) throws { if !condition { throw ConnectedCheckFailure.failed(label) } }
private func connectedJSON(_ value: [String: Any], status: Int = 200) throws -> ConnectedHTTPResult { ConnectedHTTPResult(status: status, data: try JSONSerialization.data(withJSONObject: value)) }
private final class ConnectedMemoryStore: ConnectedTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ConnectedToken] = [:]
    func read(key: String) throws -> ConnectedToken? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ token: ConnectedToken, key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = token }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}
private actor ConnectedMockTransport: ConnectedTransport {
    private var responses: [ConnectedHTTPResult]
    private var requests: [URLRequest] = []
    init(_ responses: [ConnectedHTTPResult]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> ConnectedHTTPResult {
        requests.append(request)
        guard !responses.isEmpty else { throw ConnectedCheckFailure.failed("unexpected HTTP call") }
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}
private final class ConnectedBlockingBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ value: Result<Value, Error>) { lock.lock(); result = value; lock.unlock() }
    func take() throws -> Value { lock.lock(); defer { lock.unlock() }; guard let result else { throw ConnectedCheckFailure.failed("missing async result") }; return try result.get() }
}
private func connectedWait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let signal = DispatchSemaphore(value: 0), box = ConnectedBlockingBox<T>()
    Task.detached {
        do { box.store(.success(try await body())) } catch { box.store(.failure(error)) }
        signal.signal()
    }
    guard signal.wait(timeout: .now() + 20) == .success else { throw ConnectedCheckFailure.failed("mock check timed out") }
    return try box.take()
}
private func connectedConfig(_ provider: ConnectedProvider, access: ConnectedAccess = .recycle) -> ConnectedConfiguration {
    ConnectedConfiguration(provider: provider, clientID: "public-test-client", redirectURI: "local.aiyou.AIYOUClean:/oauth/" + provider.serviceFamily, access: access)
}
private func connectedFixtureClient(_ provider: ConnectedProvider, responses: [ConnectedHTTPResult], access: ConnectedAccess = .recycle) throws -> (ConnectedAccountClient, ConnectedMockTransport) {
    let config = connectedConfig(provider, access: access), store = ConnectedMemoryStore(), transport = ConnectedMockTransport(responses)
    try store.write(ConnectedToken(accessToken: "test-only-noncredential", expiresAt: Date().addingTimeInterval(3600), scopes: config.scopes), key: config.credentialKey)
    return (try ConnectedAccountClient(configuration: config, transport: transport, tokenStore: store), transport)
}
private func connectedBody(_ request: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:] }

/// HTTP mocks plus generated IPv4-loopback fixtures; no external network, Keychain, authentication sheet or real account.
func runConnectedChecks() throws {
    let expectedVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    checkEqual(ConnectedOAuthRequest.challenge(for: expectedVerifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let config = connectedConfig(.googleDrive)
    let request = try ConnectedOAuthRequest(configuration: config, verifier: expectedVerifier, state: String(repeating: "s", count: 43))
    var callback = URLComponents(string: config.redirectURI)!
    callback.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: request.state)]
    checkEqual(try request.validatedCode(from: callback.url!), "synthetic-code")
    var wrong = callback; wrong.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: "wrong-state")]
    checkThrows(try { _ = try request.validatedCode(from: wrong.url!) }())
    wrong = callback; wrong.queryItems?.append(.init(name: "state", value: request.state))
    checkThrows(try { _ = try request.validatedCode(from: wrong.url!) }())
    wrong = callback; wrong.queryItems?.append(.init(name: "access_token", value: "synthetic-token"))
    checkThrows(try { _ = try request.validatedCode(from: wrong.url!) }())
    wrong = callback; wrong.fragment = "access_token=synthetic-token"
    checkThrows(try { _ = try request.validatedCode(from: wrong.url!) }())
    wrong = callback; wrong.path = "/different-path"
    checkThrows(try { _ = try request.validatedCode(from: wrong.url!) }())
    checkThrows(try { _ = try request.validatedCode(from: callback.url!, now: request.createdAt.addingTimeInterval(601)) }())
    checkFalse(request.configuration.scopes.contains("https://mail.google.com/"))
    checkFalse(connectedConfig(.outlook).scopes.contains(where: { $0.contains("Mail.Send") }))
    checkEqual(connectedConfig(.oneDrive, access: .browse).scopes, ["https://graph.microsoft.com/Files.Read"])
    checkEqual(connectedConfig(.gmail, access: .browse).scopes, ["https://www.googleapis.com/auth/gmail.metadata"])
    checkEqual(connectedConfig(.dropbox, access: .browse).scopes, ["files.metadata.read"])
    let completed = try connectedWait { try await connectedAPIChecks() }
    checkEqual(completed, 12)
    let loopback = ConnectedConfiguration(provider: .googleDrive, clientID: "public-fixture.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:0/oauth/googleDrive")
    var alternate = loopback; alternate.redirectURI = "http://127.0.0.1:54321/oauth/googleDrive"
    checkTrue(loopback.validationIssue == nil)
    checkEqual(loopback.credentialKey, alternate.credentialKey)
    alternate.provider = .gmail; checkFalse(loopback.credentialKey == alternate.credentialKey)
    alternate = loopback; alternate.clientID = "other-public-client"; checkFalse(loopback.credentialKey == alternate.credentialKey)
    alternate = loopback; alternate.redirectURI = "http://127.0.0.1:0/oauth/different"; checkFalse(loopback.credentialKey == alternate.credentialKey)
    alternate = loopback; alternate.access = .recycle; checkFalse(loopback.credentialKey == alternate.credentialKey)
    for host in ["localhost", "0.0.0.0", "127.0.0.2", "192.0.2.1", "[::1]"] {
        alternate = loopback; alternate.redirectURI = "http://" + host + ":0/oauth/googleDrive"
        checkTrue(alternate.validationIssue != nil)
    }
    alternate = loopback; alternate.provider = .oneDrive; checkTrue(alternate.validationIssue != nil)
    checkEqual(ConnectedConfiguration.suggestedRedirect(provider: .gmail, clientID: ""), "http://127.0.0.1:0/oauth/gmail")
    let fixtureCount = try connectedWait { try await connectedLoopbackChecks() }
    checkEqual(fixtureCount, 4)
}

private func connectedAPIChecks() async throws -> Int {
    var passed = 0
    // Invalid state must be rejected before a token request; a used authorization is single-use.
    do {
        let c = connectedConfig(.googleDrive), store = ConnectedMemoryStore()
        let mock = ConnectedMockTransport([try connectedJSON(["access_token": "test-only-noncredential", "token_type": "Bearer", "expires_in": 3600, "scope": c.scopes.joined(separator: " ")])])
        let client = try ConnectedAccountClient(configuration: c, transport: mock, tokenStore: store)
        let badRequest = try await client.createAuthorizationRequest()
        var callback = URLComponents(string: c.redirectURI)!
        callback.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: "wrong")]
        do { try await client.completeAuthorization(request: badRequest, callback: callback.url!); throw ConnectedCheckFailure.failed("state accepted") } catch ConnectedError.stateMismatch {}
        try expectConnected(await mock.captured().isEmpty, "state rejected before network")
        let valid = try await client.createAuthorizationRequest()
        callback.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: valid.state)]
        try await client.completeAuthorization(request: valid, callback: callback.url!)
        let calls = await mock.captured(), form = String(data: calls[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        try expectConnected(calls.count == 1 && form.contains("code_verifier=") && !form.contains("client_secret") && calls[0].url?.query == nil, "PKCE exchange uses POST body")
        do { try await client.completeAuthorization(request: valid, callback: callback.url!); throw ConnectedCheckFailure.failed("authorization replay accepted") } catch ConnectedError.invalidConfiguration {}
        try expectConnected(try await client.hasUsableCredentials(), "credential stored through injected store")
        try await client.disconnect(); try expectConnected(!(try await client.hasUsableCredentials()), "local disconnect clears credential")
        passed += 1
    }
    // Google Drive uses recoverable trashed=true, confirms exact observed version and refuses replay.
    do {
        let row: [String: Any] = ["id":"drive-file", "name":"fixture.txt", "version":"7", "size":"12", "ownedByMe":true, "capabilities":["canTrash":true]]
        var current = row; current["trashed"] = false
        let (client, mock) = try connectedFixtureClient(.googleDrive, responses: [try connectedJSON(["files":[row], "nextPageToken":"next-synthetic"]), try connectedJSON(current), try connectedJSON(["id":"drive-file", "trashed":true])])
        let page = try await client.listPage(); try expectConnected(page.items.count == 1 && page.nextCursor != nil, "Drive page parsed")
        let plan = try await client.prepareRecycle(page.items)
        do { _ = try await client.recycle(plan, confirmed: false); throw ConnectedCheckFailure.failed("unconfirmed recycle accepted") } catch ConnectedError.missingConfirmation {}
        try expectConnected(await mock.captured().count == 1, "no mutation before confirmation")
        let result = try await client.recycle(plan, confirmed: true)
        try expectConnected(result.recycledIDs == ["drive-file"] && result.failures.isEmpty, "Drive trash result")
        let calls = await mock.captured()
        try expectConnected(calls.last?.httpMethod == "PATCH" && connectedBody(calls.last!)["trashed"] as? Bool == true && !calls.contains { $0.httpMethod == "DELETE" }, "Drive never permanent delete")
        let query = URLComponents(url: calls[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try expectConnected(query.contains { $0.name == "pageSize" && $0.value == "50" }, "Drive fixed page size")
        do { _ = try await client.recycle(plan, confirmed: true); throw ConnectedCheckFailure.failed("plan replay accepted") } catch ConnectedError.expiredPlan {}
        passed += 1
    }
    // A changed object is not recycled; current-page observations replace earlier pages.
    do {
        let a: [String: Any] = ["id":"a", "name":"a", "version":"1", "ownedByMe":true, "capabilities":["canTrash":true]]
        let b: [String: Any] = ["id":"b", "name":"b", "version":"1", "ownedByMe":true, "capabilities":["canTrash":true]]
        var changed = b; changed["version"] = "2"
        let (client, mock) = try connectedFixtureClient(.googleDrive, responses: [try connectedJSON(["files":[a]]), try connectedJSON(["files":[b]]), try connectedJSON(changed)])
        let old = try await client.listPage(), current = try await client.listPage(cursor: "next")
        do { _ = try await client.prepareRecycle(old.items); throw ConnectedCheckFailure.failed("old page remained actionable") } catch ConnectedError.staleSelection {}
        let plan = try await client.prepareRecycle(current.items), outcome = try await client.recycle(plan, confirmed: true)
        let callCount = await mock.captured().count
        try expectConnected(outcome.recycledIDs.isEmpty && outcome.failures.count == 1 && callCount == 3, "changed Drive object blocked without PATCH")
        passed += 1
    }
    // Bearer tokens are never sent to a hostile nextLink.
    do {
        let (client, mock) = try connectedFixtureClient(.oneDrive, responses: [try connectedJSON(["value":[], "@odata.nextLink":"https://example.invalid/v1.0/me/drive/root/children"])])
        let page = try await client.listPage()
        do { _ = try await client.listPage(cursor: page.nextCursor); throw ConnectedCheckFailure.failed("hostile page accepted") } catch ConnectedError.unsafeURL {}
        try expectConnected(await mock.captured().count == 1, "hostile nextLink not requested")
        passed += 1
    }
    // A server pagination URL cannot expand the fixed metadata projection or page budget.
    do {
        let (client, mock) = try connectedFixtureClient(.outlook, responses: [try connectedJSON(["value":[], "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$select=body&$expand=attachments&$top=100000&$skiptoken=fixture-cursor"]), try connectedJSON(["value":[]])])
        let page = try await client.listPage()
        _ = try await client.listPage(cursor: page.nextCursor)
        let calls = await mock.captured()
        let query = URLComponents(url: calls[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try expectConnected(query.first { $0.name == "$top" }?.value == "50", "nextLink page limit retained")
        try expectConnected(query.first { $0.name == "$select" }?.value?.contains("body") == false && !query.contains { $0.name == "$expand" }, "nextLink cannot expand mail fields")
        try expectConnected(query.first { $0.name == "$skiptoken" }?.value == "fixture-cursor", "provider paging token retained")
        passed += 1
    }
    // OneDrive DELETE is the documented recycle endpoint and always carries the observed eTag.
    do {
        let row: [String: Any] = ["id":"one!file", "name":"fixture", "size":8, "eTag":"\"tag1\"", "file":[:]]
        let (client, mock) = try connectedFixtureClient(.oneDrive, responses: [try connectedJSON(["value":[row]]), ConnectedHTTPResult(status:204,data:Data())])
        let page = try await client.listPage(), plan = try await client.prepareRecycle(page.items)
        let outcome = try await client.recycle(plan, confirmed:true)
        let calls = await mock.captured()
        try expectConnected(outcome.recycledIDs.count == 1 && calls.last?.httpMethod == "DELETE" && calls.last?.value(forHTTPHeaderField:"If-Match") == "\"tag1\"" && !(calls.last?.url?.path.contains("permanentDelete") ?? true), "OneDrive conditional recycle")
        passed += 1
    }
    // Dropbox revision matching is atomic via parent_rev, with recoverable delete_v2 only.
    do {
        let row: [String: Any] = [".tag":"file", "id":"id:fixture", "name":"fixture", "path_display":"/fixture", "rev":"abcdef123", "size":20]
        let (client,mock) = try connectedFixtureClient(.dropbox,responses:[try connectedJSON(["entries":[row],"has_more":false]),try connectedJSON(["metadata":row])])
        let page = try await client.listPage(), plan = try await client.prepareRecycle(page.items)
        let outcome = try await client.recycle(plan,confirmed:true), calls = await mock.captured()
        try expectConnected(outcome.recycledIDs.count == 1 && calls.last?.url?.path == "/2/files/delete_v2" && connectedBody(calls.last!)["parent_rev"] as? String == "abcdef123" && connectedBody(calls.last!)["path"] as? String == "id:fixture", "Dropbox revision-gated soft delete")
        passed += 1
    }
    // Gmail reads only metadata and uses trash, never send or permanent-delete routes.
    do {
        let metadata: [String: Any] = ["id":"mail1","historyId":"44","labelIds":["INBOX"],"sizeEstimate":99,"payload":["headers":[["name":"Subject","value":"Fixture subject"],["name":"From","value":"fixture@example.invalid"]]]]
        let (client,mock) = try connectedFixtureClient(.gmail,responses:[try connectedJSON(["messages":[["id":"mail1"]]]),try connectedJSON(metadata),try connectedJSON(metadata),try connectedJSON(["id":"mail1","labelIds":["TRASH"]])])
        let page = try await client.listPage(), plan = try await client.prepareRecycle(page.items)
        let outcome = try await client.recycle(plan,confirmed:true), calls = await mock.captured()
        let metadataQuery = URLComponents(url:calls[1].url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
        try expectConnected(outcome.recycledIDs.count == 1 && calls.last?.url?.path.hasSuffix("/trash") == true && metadataQuery.contains { $0.name == "format" && $0.value == "metadata" } && !calls.contains { $0.url?.path.hasSuffix("/send") == true || $0.httpMethod == "DELETE" }, "Gmail metadata + trash only")
        passed += 1
    }
    // Outlook moves into Deleted Items; it never requests message bodies or a send scope.
    do {
        let row: [String: Any] = ["id":"outlook-fixture","subject":"Fixture","@odata.etag":"etag-fixture","from":["emailAddress":["address":"fixture@example.invalid"]],"receivedDateTime":"2026-10-30T00:00:00Z"]
        let (client,mock) = try connectedFixtureClient(.outlook,responses:[try connectedJSON(["value":[row]]),try connectedJSON(row),try connectedJSON(["id":"outlook-fixture","parentFolderId":"deleted-items-id"],status:201)])
        let page = try await client.listPage(), plan = try await client.prepareRecycle(page.items)
        let outcome = try await client.recycle(plan,confirmed:true), calls = await mock.captured()
        let fields = URLComponents(url:calls[0].url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "$select" }?.value ?? ""
        try expectConnected(outcome.recycledIDs.count == 1 && connectedBody(calls.last!)["destinationId"] as? String == "deleteditems" && calls.last?.url?.path.hasSuffix("/move") == true && !fields.lowercased().contains("body") && calls[0].value(forHTTPHeaderField:"Prefer") == "IdType=\"ImmutableId\"", "Outlook metadata + move only")
        passed += 1
    }
    // Provider pages over the limit and oversized response bodies are rejected before caching.
    do {
        let rows = (0..<51).map { ["id":"file\($0)","name":"fixture\($0)"] }
        let (client,_) = try connectedFixtureClient(.oneDrive,responses:[try connectedJSON(["value":rows])])
        do { _ = try await client.listPage(); throw ConnectedCheckFailure.failed("oversized page accepted") } catch ConnectedError.invalidResponse {}
        let (large,_) = try connectedFixtureClient(.oneDrive,responses:[ConnectedHTTPResult(status:200,data:Data(repeating:32,count:2_097_153))])
        do { _ = try await large.listPage(); throw ConnectedCheckFailure.failed("oversized response accepted") } catch ConnectedError.invalidResponse {}
        passed += 1
    }
    // Read-only authorization cannot prepare a mutation even if a caller forges canRecycle=true.
    do {
        let (client,mock) = try connectedFixtureClient(.oneDrive,responses:[],access:.browse)
        let fake = ConnectedItem(id:"forged",provider:.oneDrive,name:"fixture",location:"root",detail:"",version:"etag",canRecycle:true)
        do { _ = try await client.prepareRecycle([fake]); throw ConnectedCheckFailure.failed("readonly mutation accepted") } catch ConnectedError.insufficientScope {}
        try expectConnected(await mock.captured().isEmpty,"readonly forged mutation made no request")
        passed += 1
    }
    // A token response with a narrower scope never becomes a usable credential.
    do {
        let c = connectedConfig(.googleDrive), store = ConnectedMemoryStore()
        let mock = ConnectedMockTransport([try connectedJSON(["access_token":"test-only-noncredential","token_type":"Bearer","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.metadata.readonly"])])
        let client = try ConnectedAccountClient(configuration:c,transport:mock,tokenStore:store), request = try await client.createAuthorizationRequest()
        var callback = URLComponents(string:c.redirectURI)!
        callback.queryItems = [.init(name:"code",value:"synthetic-code"),.init(name:"state",value:request.state)]
        do { try await client.completeAuthorization(request:request,callback:callback.url!); throw ConnectedCheckFailure.failed("narrow scope accepted") } catch ConnectedError.insufficientScope {}
        try expectConnected(try store.read(key:c.credentialKey) == nil,"narrow token never saved")
        passed += 1
    }
    return passed
}


private func connectedProbeTCP(_ address: String, port: UInt16) -> Bool {
    // No request, code or state is sent to the probe address.
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }; defer { Darwin.close(descriptor) }
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    var endpoint = sockaddr_in()
    endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = port.bigEndian
    guard inet_pton(AF_INET, address, &endpoint.sin_addr) == 1 else { return false }
    let result = withUnsafePointer(to: &endpoint) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&pending, 1, 150) > 0 else { return false }
    var failure: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { return false }
    return failure == 0
}
private func connectedLANIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }; defer { freeifaddrs(head) }
    var node = head
    while let current = node {
        defer { node = current.pointee.ifa_next }
        guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let endpoint = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
        var ip = endpoint.pointee.sin_addr
        guard inet_ntop(AF_INET, &ip, &text, socklen_t(text.count)) != nil else { continue }
        return String(cString: text)
    }
    return nil
}
private func connectedWaitForClosedPort(_ port: UInt16) async throws {
    for _ in 0..<20 {
        if !connectedProbeTCP("127.0.0.1", port: port) { return }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw ConnectedCheckFailure.failed("temporary listener was not closed")
}
private func connectedFixtureHTTP(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url); request.httpMethod = method
    let (body, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ConnectedCheckFailure.failed("fixture did not return HTTP") }
    return (body, http)
}
private func connectedLoopbackChecks() async throws -> Int {
    let base = ConnectedConfiguration(provider: .googleDrive, clientID: "public-fixture.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:0/oauth/googleDrive")
    var passed = 0
    // A generated fixture exercises only the local listener and a mocked token endpoint.
    do {
        let listener = try ConnectedLoopbackListener(configuration: base, timeout: 5)
        let bound = try await listener.start(); defer { listener.cancel() }
        let port = UInt16(try unwrap(URLComponents(string: bound.redirectURI)?.port))
        try expectConnected(URL(string: bound.redirectURI)?.host == "127.0.0.1" && port != 0, "listener advertises literal IPv4 loopback")
        try expectConnected(!connectedProbeTCP("127.0.0.2", port: port), "listener is not wildcard-bound")
        if let lan = connectedLANIPv4() { try expectConnected(!connectedProbeTCP(lan, port: port), "listener does not accept LAN interface") }
        let store = ConnectedMemoryStore()
        let mock = ConnectedMockTransport([try connectedJSON(["access_token":"test-only-noncredential","token_type":"Bearer","expires_in":3600,"scope":base.scopes.joined(separator:" ")])])
        let client = try ConnectedAccountClient(configuration: base, transport: mock, tokenStore: store)
        let oauth = try await client.createAuthorizationRequest(redirectURI: bound.redirectURI)
        try await listener.arm(oauth)
        var callback = URLComponents(string: bound.redirectURI)!
        callback.queryItems = [.init(name:"code",value:"synthetic-local-code"),.init(name:"state",value:oauth.state)]
        let post = try await connectedFixtureHTTP(callback.url!, method:"POST")
        try expectConnected(post.1.statusCode == 400,"loopback rejects POST")
        var wrong = callback; wrong.path = "/oauth/not-the-callback"
        let badPath = try await connectedFixtureHTTP(wrong.url!)
        try expectConnected(badPath.1.statusCode == 400,"loopback rejects other paths")
        wrong = callback; wrong.queryItems = [.init(name:"code",value:"synthetic-local-code"),.init(name:"state",value:"wrong-state")]
        let badState = try await connectedFixtureHTTP(wrong.url!)
        try expectConnected(badState.1.statusCode == 400,"loopback does not finish on wrong state")
        let http = try await connectedFixtureHTTP(callback.url!)
        let returned = try await listener.waitForCallback()
        let staticPage = String(data:http.0,encoding:.utf8) ?? ""
        try expectConnected(http.1.statusCode == 200 && http.1.value(forHTTPHeaderField:"Cache-Control") == "no-store" && !staticPage.contains("synthetic-local-code") && !staticPage.contains(oauth.state),"loopback response is static and noncacheable")
        try expectConnected(returned == callback.url!,"loopback returns only validated callback")
        try await client.completeAuthorization(request:oauth,callback:returned)
        let calls = await mock.captured()
        let tokenBody = String(data:calls[0].httpBody ?? Data(),encoding:.utf8) ?? ""
        let bodyFields = URLComponents(string:"https://fixture.invalid/?" + tokenBody)?.queryItems ?? []
        let authFields = URLComponents(url:oauth.authorizationURL,resolvingAgainstBaseURL:false)?.queryItems ?? []
        try expectConnected(bodyFields.first { $0.name == "redirect_uri" }?.value == bound.redirectURI && authFields.first { $0.name == "redirect_uri" }?.value == bound.redirectURI,"authorization and token exchange use identical ephemeral redirect")
        try expectConnected(try await client.hasUsableCredentials(),"base normalized credential key finds bound-port credential")
        try await connectedWaitForClosedPort(port)
        passed += 1
    }
    do {
        let listener = try ConnectedLoopbackListener(configuration: base, timeout: 5)
        let bound = try await listener.start(), oauth = try ConnectedOAuthRequest(configuration: bound)
        let port = UInt16(try unwrap(URLComponents(string:bound.redirectURI)?.port))
        try await listener.arm(oauth); listener.cancel()
        do { _ = try await listener.waitForCallback(); throw ConnectedCheckFailure.failed("cancelled listener returned success") } catch ConnectedError.cancelled {}
        try await connectedWaitForClosedPort(port); passed += 1
    }
    do {
        let listener = try ConnectedLoopbackListener(configuration: base, timeout: 0.15)
        let bound = try await listener.start(), oauth = try ConnectedOAuthRequest(configuration: bound)
        let port = UInt16(try unwrap(URLComponents(string:bound.redirectURI)?.port))
        try await listener.arm(oauth)
        do { _ = try await listener.waitForCallback(); throw ConnectedCheckFailure.failed("timed-out listener returned success") } catch ConnectedError.expiredAuthorization {}
        try await connectedWaitForClosedPort(port); passed += 1
    }
    do {
        let listener = try ConnectedLoopbackListener(configuration: base, timeout: 5)
        let bound = try await listener.start(), oauth = try ConnectedOAuthRequest(configuration: bound)
        let port = UInt16(try unwrap(URLComponents(string:bound.redirectURI)?.port))
        try await listener.arm(oauth)
        var oversized = URLComponents(string:bound.redirectURI)!
        oversized.queryItems = [.init(name:"code",value:String(repeating:"x",count:9_000)),.init(name:"state",value:oauth.state)]
        do { _ = try await connectedFixtureHTTP(oversized.url!) } catch { /* Exceeding 8 KiB closes the connection without reflecting it. */ }
        do { _ = try await listener.waitForCallback(); throw ConnectedCheckFailure.failed("oversized callback accepted") } catch ConnectedError.invalidCallback {}
        try await connectedWaitForClosedPort(port); passed += 1
    }
    return passed
}
