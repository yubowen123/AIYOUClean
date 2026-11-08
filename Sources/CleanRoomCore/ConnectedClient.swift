import Foundation

/// Metadata lives only in this actor and the UI. No listing or message body is written to disk.
public actor ConnectedAccountClient {
    public let configuration: ConnectedConfiguration
    private let transport: any ConnectedTransport
    private let tokenStore: any ConnectedTokenStore
    private var observed: [String: ConnectedItem] = [:]
    private var pendingPlan: ConnectedRecyclePlan?
    private var pendingOAuth: ConnectedOAuthRequest?
    private var currentContainer: String?
    public init(configuration: ConnectedConfiguration, transport: any ConnectedTransport = ConnectedURLSessionTransport(), tokenStore: any ConnectedTokenStore = ConnectedKeychainStore()) throws {
        guard configuration.validationIssue == nil else { throw configuration.clientID.isEmpty ? ConnectedError.unconfigured : ConnectedError.invalidConfiguration }
        self.configuration = configuration; self.transport = transport; self.tokenStore = tokenStore
    }
    public func hasUsableCredentials(now: Date = Date()) throws -> Bool {
        guard let token = try tokenStore.read(key: configuration.credentialKey) else { return false }
        return token.expiresAt > now.addingTimeInterval(30) || (configuration.persistentConnection && token.refreshToken != nil)
    }
    public func createAuthorizationRequest(redirectURI: String? = nil) throws -> ConnectedOAuthRequest {
        var runtime = configuration
        if let redirectURI { runtime.redirectURI = redirectURI }
        guard runtime.validationIssue == nil, runtime.credentialKey == configuration.credentialKey else { throw ConnectedError.invalidConfiguration }
        let request = try ConnectedOAuthRequest(configuration: runtime)
        pendingOAuth = request; return request
    }
    public func authorize(using session: ConnectedOAuthWebSession) async throws {
        if configuration.isGoogleLoopback {
            let listener = try ConnectedLoopbackListener(configuration: configuration)
            do {
                let bound = try await listener.start()
                try Task.checkCancellation()
                let request = try createAuthorizationRequest(redirectURI: bound.redirectURI)
                try await listener.arm(request)
                let callback = try await session.authenticate(request, loopback: listener)
                try await completeAuthorization(request: request, callback: callback)
                listener.cancel()
            } catch {
                pendingOAuth = nil; listener.cancel(); throw error
            }
        } else {
            let request = try createAuthorizationRequest()
            do {
                let callback = try await session.authenticate(request)
                try await completeAuthorization(request: request, callback: callback)
            } catch { pendingOAuth = nil; throw error }
        }
    }
    public func completeAuthorization(request: ConnectedOAuthRequest, callback: URL) async throws {
        guard request.configuration.credentialKey == configuration.credentialKey, let pending = pendingOAuth, pending.configuration == request.configuration, pending.state == request.state, pending.verifier == request.verifier, pending.createdAt == request.createdAt else { throw ConnectedError.invalidConfiguration }
        pendingOAuth = nil
        let code = try request.validatedCode(from: callback)
        let result = try await transport.send(request.tokenRequest(code: code))
        let token = try parsedToken(result, fallbackRefresh: nil)
        try tokenStore.write(token, key: configuration.credentialKey)
        observed = [:]; pendingPlan = nil
    }
    public func disconnect() throws {
        try tokenStore.remove(key: configuration.credentialKey)
        observed = [:]; pendingPlan = nil; pendingOAuth = nil
    }
    private func parsedToken(_ response: ConnectedHTTPResult, fallbackRefresh: String?) throws -> ConnectedToken {
        guard (200..<300).contains(response.status) else { throw ConnectedError.http(response.status) }
        let object = try json(response.data)
        guard let access = object["access_token"] as? String, !access.isEmpty, access.count <= 32768, !access.contains(where: { $0.isNewline }),
              let expires = number(object["expires_in"]), expires > 0, expires <= 31_536_000,
              (object["token_type"] as? String)?.lowercased() == "bearer" else { throw ConnectedError.invalidResponse }
        let scopeText = object["scope"] as? String
        guard (scopeText?.utf8.count ?? 0) <= 16384 else { throw ConnectedError.invalidResponse }
        let granted = scopeText?.split(separator: " ").map(String.init) ?? configuration.scopes
        guard granted.count <= 32, granted.allSatisfy({ $0.count <= 1024 }) else { throw ConnectedError.invalidResponse }
        func canonical(_ scope: String) -> String { scope.replacingOccurrences(of: "https://graph.microsoft.com/", with: "").lowercased() }
        let grantedSet = Set(granted.map(canonical))
        guard configuration.scopes.filter({ $0 != "offline_access" }).allSatisfy({ grantedSet.contains(canonical($0)) }) else { throw ConnectedError.insufficientScope }
        let refresh = configuration.persistentConnection ? ((object["refresh_token"] as? String) ?? fallbackRefresh) : nil
        guard (refresh?.count ?? 0) <= 32768, !(refresh?.contains(where: { $0.isNewline }) ?? false) else { throw ConnectedError.invalidResponse }
        return ConnectedToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires), scopes: granted)
    }
    private func accessToken() async throws -> String {
        guard let token = try tokenStore.read(key: configuration.credentialKey) else { throw ConnectedError.missingAuthorization }
        if token.expiresAt > Date().addingTimeInterval(30) { return token.accessToken }
        guard configuration.persistentConnection, let refresh = token.refreshToken, !refresh.isEmpty else { throw ConnectedError.missingAuthorization }
        var fields = ["client_id": configuration.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
        if configuration.provider.serviceFamily == "microsoft" { fields["scope"] = configuration.scopes.joined(separator: " ") }
        let result = try await transport.send(ConnectedOAuthRequest.formRequest(configuration: configuration, fields: fields))
        let updated = try parsedToken(result, fallbackRefresh: refresh)
        try tokenStore.write(updated, key: configuration.credentialKey)
        return updated.accessToken
    }
    private func json(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_097_152, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectedError.invalidResponse }
        return value
    }
    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    private func string(_ object: [String: Any], _ key: String) -> String { object[key] as? String ?? "" }
    private func makeURL(_ base: String, query: [(String, String)] = []) throws -> URL {
        guard var c = URLComponents(string: base) else { throw ConnectedError.unsafeURL }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = c.url else { throw ConnectedError.unsafeURL }
        try ConnectedURL.validate(url, provider: configuration.provider)
        return url
    }
    private func send(_ url: URL, method: String = "GET", body: [String: Any]? = nil, etag: String? = nil) async throws -> [String: Any] {
        try ConnectedURL.validate(url, provider: configuration.provider)
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if configuration.provider == .outlook { request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer") }
        if let etag {
            guard !etag.contains(where: { $0.isNewline }), etag.count < 8192 else { throw ConnectedError.invalidResponse }
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response = try await transport.send(request)
        if response.status == 401 { try? tokenStore.remove(key: configuration.credentialKey); throw ConnectedError.missingAuthorization }
        guard (200..<300).contains(response.status) else { throw ConnectedError.http(response.status) }
        return response.status == 204 || response.data.isEmpty ? [:] : try json(response.data)
    }
    public func listPage(cursor: String? = nil, containerID: String? = nil) async throws -> ConnectedPage {
        guard (cursor?.count ?? 0) <= 32768 else { throw ConnectedError.limitReached }
        let page: ConnectedPage
        switch configuration.provider {
        case .googleDrive: page = try await listDrive(cursor)
        case .gmail: page = try await listGmail(cursor)
        case .oneDrive: page = try await listOneDrive(cursor, containerID: containerID)
        case .outlook: page = try await listOutlook(cursor)
        case .dropbox: page = try await listDropbox(cursor)
        }
        guard page.items.count <= 50 else { throw ConnectedError.limitReached }
        observed.removeAll(keepingCapacity: false)
        for item in page.items { observed[item.id] = item }
        if configuration.provider == .oneDrive { currentContainer = containerID }
        pendingPlan = nil
        return page
    }
    private func listDrive(_ cursor: String?) async throws -> ConnectedPage {
        var q = [("q", "trashed = false and 'me' in owners and mimeType != 'application/vnd.google-apps.folder'"), ("pageSize", "50"), ("fields", "nextPageToken,files(id,name,mimeType,size,modifiedTime,version,ownedByMe,capabilities(canTrash))")]
        if let cursor { q.append(("pageToken", cursor)) }
        let value = try await send(makeURL("https://www.googleapis.com/drive/v3/files", query: q))
        let rows = value["files"] as? [[String: Any]] ?? []
        guard rows.count <= 50 else { throw ConnectedError.invalidResponse }
        let items = try rows.map { row -> ConnectedItem in
            let id = string(row, "id"), version = string(row, "version")
            guard !id.isEmpty else { throw ConnectedError.invalidResponse }
            let allowed = (row["capabilities"] as? [String: Any])?["canTrash"] as? Bool == true && row["ownedByMe"] as? Bool == true
            return ConnectedItem(id: id, provider: .googleDrive, name: string(row, "name"), location: "我的云端硬盘 · ownedByMe", detail: string(row, "mimeType") + " · " + string(row, "modifiedTime"), bytes: Int64(number(row["size"]) ?? 0), version: version, canRecycle: configuration.access == .recycle && allowed && !version.isEmpty)
        }
        return ConnectedPage(items: items, nextCursor: value["nextPageToken"] as? String, scopeDescription: "仅本人拥有、未入回收站的文件；不列共享盘、不处理文件夹。")
    }
    private func gmailItem(_ object: [String: Any]) throws -> ConnectedItem {
        let id = string(object, "id"), version = string(object, "historyId")
        guard !id.isEmpty else { throw ConnectedError.invalidResponse }
        let labels = object["labelIds"] as? [String] ?? []
        let headers = (object["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        func header(_ key: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == key.lowercased() }?["value"] as? String ?? "" }
        let subject = header("Subject")
        return ConnectedItem(id: id, provider: .gmail, name: subject.isEmpty ? "（无主题）" : subject, location: "收件箱", detail: header("From") + " · " + header("Date"), bytes: Int64(number(object["sizeEstimate"]) ?? 0), version: version, canRecycle: configuration.access == .recycle && labels.contains("INBOX") && !labels.contains("TRASH") && !labels.contains("DRAFT") && !version.isEmpty)
    }
    private func gmailMetadata(_ id: String) async throws -> [String: Any] {
        try await send(makeURL("https://gmail.googleapis.com/gmail/v1/users/me/messages/" + (try ConnectedURL.path(id)), query: [("format", "metadata"), ("metadataHeaders", "Subject"), ("metadataHeaders", "From"), ("metadataHeaders", "Date"), ("fields", "id,labelIds,internalDate,sizeEstimate,historyId,payload/headers")]))
    }
    private func listGmail(_ cursor: String?) async throws -> ConnectedPage {
        var q = [("labelIds", "INBOX"), ("maxResults", "50"), ("includeSpamTrash", "false"), ("fields", "messages/id,nextPageToken")]
        if let cursor { q.append(("pageToken", cursor)) }
        let value = try await send(makeURL("https://gmail.googleapis.com/gmail/v1/users/me/messages", query: q))
        let rows = value["messages"] as? [[String: Any]] ?? []
        guard rows.count <= 50 else { throw ConnectedError.invalidResponse }
        var items: [ConnectedItem] = []
        for row in rows {
            try Task.checkCancellation()
            let id = string(row, "id")
            let object = try await gmailMetadata(id)
            guard string(object, "id") == id else { throw ConnectedError.invalidResponse }
            items.append(try gmailItem(object))
        }
        return ConnectedPage(items: items, nextCursor: value["nextPageToken"] as? String, scopeDescription: "仅 Gmail 收件箱，每页最多 50 封；只读主题、发件人与大小等元数据，不读取正文和附件。")
    }
    private func graphPageURL(_ cursor: String?, base: String, query: [(String, String)]) throws -> URL {
        if let cursor {
            guard let u = URL(string: cursor), u.path.hasSuffix("/children") || u.path.hasSuffix("/messages") else { throw ConnectedError.unsafeURL }
            try ConnectedURL.validate(u, provider: configuration.provider)
            guard var components = URLComponents(url: u, resolvingAgainstBaseURL: false) else { throw ConnectedError.unsafeURL }
            // Provider pagination may carry a cursor, but must not broaden the
            // fixed metadata projection or page size chosen by this client.
            let cursorItems = (components.queryItems ?? []).filter { $0.name == "$skiptoken" || $0.name == "$skip" }
            guard cursorItems.count <= 2, cursorItems.allSatisfy({ ($0.value?.utf8.count ?? 0) <= 8192 }) else { throw ConnectedError.unsafeURL }
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + cursorItems
            guard let bounded = components.url else { throw ConnectedError.unsafeURL }; return bounded
        }
        return try makeURL(base, query: query)
    }
    private func listOneDrive(_ cursor: String?, containerID: String?) async throws -> ConnectedPage {
        var base = "https://graph.microsoft.com/v1.0/me/drive/root/children"
        if let id = containerID {
            guard id == currentContainer || observed[id]?.isContainer == true else { throw ConnectedError.staleSelection }
            base = "https://graph.microsoft.com/v1.0/me/drive/items/" + (try ConnectedURL.path(id)) + "/children"
        }
        let value = try await send(graphPageURL(cursor, base: base, query: [("$top", "50"), ("$select", "id,name,size,lastModifiedDateTime,file,folder,eTag,parentReference,remoteItem,deleted")]))
        let rows = value["value"] as? [[String: Any]] ?? []
        guard rows.count <= 50 else { throw ConnectedError.invalidResponse }
        let items = try rows.map { row -> ConnectedItem in
            let id = string(row, "id"), version = string(row, "eTag"), folder = row["folder"] != nil
            guard !id.isEmpty else { throw ConnectedError.invalidResponse }
            let path = (row["parentReference"] as? [String: Any])?["path"] as? String ?? "OneDrive"
            return ConnectedItem(id: id, provider: .oneDrive, name: string(row, "name"), location: path, detail: (folder ? "文件夹 · 点击进入" : "文件") + " · " + string(row, "lastModifiedDateTime"), bytes: Int64(number(row["size"]) ?? 0), version: version, canRecycle: configuration.access == .recycle && !folder && row["remoteItem"] == nil && row["deleted"] == nil && !version.isEmpty, isContainer: folder && row["remoteItem"] == nil)
        }
        return ConnectedPage(items: items, nextCursor: value["@odata.nextLink"] as? String, scopeDescription: "当前 OneDrive 文件夹，每页最多 50 项；文件夹仅供进入，不直接回收。共享快捷方式不可回收。")
    }
    private func outlookItem(_ row: [String: Any]) throws -> ConnectedItem {
        let id = string(row, "id"), version = string(row, "@odata.etag")
        guard !id.isEmpty else { throw ConnectedError.invalidResponse }
        let sender = (row["from"] as? [String: Any])?["emailAddress"] as? [String: Any] ?? [:]
        let subject = string(row, "subject")
        return ConnectedItem(id: id, provider: .outlook, name: subject.isEmpty ? "（无主题）" : subject, location: "收件箱", detail: string(sender, "address") + " · " + string(row, "receivedDateTime"), version: version, canRecycle: configuration.access == .recycle && !version.isEmpty)
    }
    private func listOutlook(_ cursor: String?) async throws -> ConnectedPage {
        let value = try await send(graphPageURL(cursor, base: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages", query: [("$top", "50"), ("$select", "id,subject,from,receivedDateTime,parentFolderId"), ("$orderby", "receivedDateTime desc")]))
        let rows = value["value"] as? [[String: Any]] ?? []
        guard rows.count <= 50 else { throw ConnectedError.invalidResponse }
        let items = try rows.map(outlookItem)
        return ConnectedPage(items: items, nextCursor: value["@odata.nextLink"] as? String, scopeDescription: "仅 Outlook 收件箱，每页最多 50 封；请求基本邮件元数据，不请求正文、附件、发信权限。API 不返回邮件大小。")
    }
    private func listDropbox(_ cursor: String?) async throws -> ConnectedPage {
        let endpoint = cursor == nil ? "/2/files/list_folder" : "/2/files/list_folder/continue"
        let body: [String: Any] = cursor.map { ["cursor": $0] } ?? ["path": "", "recursive": true, "include_deleted": false, "limit": 50]
        let value = try await send(makeURL("https://api.dropboxapi.com" + endpoint), method: "POST", body: body)
        let rows = value["entries"] as? [[String: Any]] ?? []
        guard rows.count <= 50 else { throw ConnectedError.invalidResponse }
        let items = try rows.map { row -> ConnectedItem in
            let id = string(row, "id"), version = string(row, "rev"), file = string(row, ".tag") == "file"
            guard !id.isEmpty else { throw ConnectedError.invalidResponse }
            let sharing = row["sharing_info"] as? [String: Any] ?? [:]
            let shared = sharing["parent_shared_folder_id"] != nil || sharing["read_only"] as? Bool == true || row["has_explicit_shared_members"] as? Bool == true
            return ConnectedItem(id: id, provider: .dropbox, name: string(row, "name"), location: string(row, "path_display"), detail: file ? string(row, "server_modified") : "文件夹（只供查看）", bytes: Int64(number(row["size"]) ?? 0), version: version, canRecycle: configuration.access == .recycle && file && !shared && !version.isEmpty)
        }
        let next = value["has_more"] as? Bool == true ? value["cursor"] as? String : nil
        if value["has_more"] as? Bool == true && next == nil { throw ConnectedError.invalidResponse }
        return ConnectedPage(items: items, nextCursor: next, scopeDescription: "递归列出注册应用可访问范围（App Folder 或 Full Dropbox）的元数据；文件夹及已知共享项目不可回收。")
    }
    public func prepareRecycle(_ selected: [ConnectedItem], now: Date = Date()) throws -> ConnectedRecyclePlan {
        guard configuration.access == .recycle else { throw ConnectedError.insufficientScope }
        guard !selected.isEmpty, selected.count <= 50, Set(selected.map(\.id)).count == selected.count else { throw ConnectedError.limitReached }
        guard selected.allSatisfy({ $0.provider == configuration.provider && $0.canRecycle && !$0.isContainer && observed[$0.id] == $0 }) else { throw ConnectedError.staleSelection }
        let plan = ConnectedRecyclePlan(id: UUID(), provider: configuration.provider, items: selected, expiresAt: now.addingTimeInterval(300))
        pendingPlan = plan; return plan
    }
    public func recycle(_ plan: ConnectedRecyclePlan, confirmed: Bool, now: Date = Date()) async throws -> ConnectedRecycleOutcome {
        guard confirmed else { throw ConnectedError.missingConfirmation }
        guard let current = pendingPlan, current.id == plan.id, current.provider == plan.provider, current.items == plan.items, current.expiresAt > now else { throw ConnectedError.expiredPlan }
        guard configuration.access == .recycle, plan.items.allSatisfy({ observed[$0.id] == $0 }) else { throw ConnectedError.staleSelection }
        pendingPlan = nil // A confirmation is single-use, including after partial failure.
        var success: [String] = [], errors: [String] = []
        for item in plan.items {
            do {
                try Task.checkCancellation()
                try await recycleOne(item)
                success.append(item.id); observed.removeValue(forKey: item.id)
            } catch {
                let safeError = error as? ConnectedError ?? .network
                errors.append(item.name + "：未确认完成，请刷新并核对；" + (safeError.errorDescription ?? "请求失败"))
            }
        }
        return ConnectedRecycleOutcome(recycledIDs: success, failures: errors)
    }
    private func recycleOne(_ item: ConnectedItem) async throws {
        let id = try ConnectedURL.path(item.id)
        switch configuration.provider {
        case .googleDrive:
            let metadataURL = try makeURL("https://www.googleapis.com/drive/v3/files/" + id, query: [("fields", "id,name,version,ownedByMe,trashed,capabilities(canTrash)")])
            let current = try await send(metadataURL)
            guard string(current, "version") == item.version, string(current, "name") == item.name, current["ownedByMe"] as? Bool == true, current["trashed"] as? Bool != true, (current["capabilities"] as? [String: Any])?["canTrash"] as? Bool == true else { throw ConnectedError.staleSelection }
            let result = try await send(makeURL("https://www.googleapis.com/drive/v3/files/" + id, query: [("fields", "id,trashed")]), method: "PATCH", body: ["trashed": true])
            guard string(result, "id") == item.id, result["trashed"] as? Bool == true else { throw ConnectedError.invalidResponse }
        case .gmail:
            let current = try gmailItem(await gmailMetadata(item.id))
            guard current == item else { throw ConnectedError.staleSelection }
            let result = try await send(makeURL("https://gmail.googleapis.com/gmail/v1/users/me/messages/" + id + "/trash"), method: "POST", body: [:])
            guard string(result, "id") == item.id, (result["labelIds"] as? [String] ?? []).contains("TRASH") else { throw ConnectedError.invalidResponse }
        case .oneDrive:
            _ = try await send(makeURL("https://graph.microsoft.com/v1.0/me/drive/items/" + id), method: "DELETE", etag: item.version)
        case .outlook:
            let current = try outlookItem(await send(makeURL("https://graph.microsoft.com/v1.0/me/messages/" + id, query: [("$select", "id,subject,from,receivedDateTime,parentFolderId")])))
            guard current == item else { throw ConnectedError.staleSelection }
            let result = try await send(makeURL("https://graph.microsoft.com/v1.0/me/messages/" + id + "/move"), method: "POST", body: ["destinationId": "deleteditems"])
            guard !(result["id"] as? String ?? "").isEmpty else { throw ConnectedError.invalidResponse }
        case .dropbox:
            let result = try await send(makeURL("https://api.dropboxapi.com/2/files/delete_v2"), method: "POST", body: ["path": item.id, "parent_rev": item.version])
            guard let metadata = result["metadata"] as? [String: Any], string(metadata, "id") == item.id else { throw ConnectedError.invalidResponse }
        }
    }
}
