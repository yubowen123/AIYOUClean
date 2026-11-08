import Foundation
import CryptoKit

public enum ConnectedProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case googleDrive, gmail, oneDrive, outlook, dropbox
    public var id: String { rawValue }
    public var title: String {
        switch self { case .googleDrive: return "Google Drive"; case .gmail: return "Gmail"; case .oneDrive: return "OneDrive"; case .outlook: return "Outlook"; case .dropbox: return "Dropbox" }
    }
    public var isMail: Bool { self == .gmail || self == .outlook }
    public var serviceFamily: String {
        switch self { case .googleDrive, .gmail: return "google"; case .oneDrive, .outlook: return "microsoft"; case .dropbox: return "dropbox" }
    }
    public var recoveryURL: URL {
        switch self {
        case .googleDrive: return URL(string: "https://drive.google.com/drive/trash")!
        case .gmail: return URL(string: "https://mail.google.com/mail/u/0/#trash")!
        case .oneDrive: return URL(string: "https://onedrive.live.com/")!
        case .outlook: return URL(string: "https://outlook.live.com/mail/0/deleteditems")!
        case .dropbox: return URL(string: "https://www.dropbox.com/deleted_files")!
        }
    }
}
public enum ConnectedAccess: String, CaseIterable, Codable, Sendable {
    case browse, recycle
    public var title: String { self == .browse ? "只读列表" : "列表与回收" }
}
public struct ConnectedConfiguration: Codable, Equatable, Sendable {
    public var provider: ConnectedProvider
    public var clientID: String
    public var redirectURI: String
    public var access: ConnectedAccess
    public var persistentConnection: Bool
    public init(provider: ConnectedProvider, clientID: String, redirectURI: String, access: ConnectedAccess = .browse, persistentConnection: Bool = false) {
        self.provider = provider; self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines); self.redirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines); self.access = access; self.persistentConnection = persistentConnection
    }
    public var scopes: [String] {
        let write = access == .recycle
        var values: [String]
        switch provider {
        case .googleDrive: values = ["https://www.googleapis.com/auth/" + (write ? "drive" : "drive.metadata.readonly")]
        case .gmail: values = ["https://www.googleapis.com/auth/" + (write ? "gmail.modify" : "gmail.metadata")]
        case .oneDrive: values = ["https://graph.microsoft.com/" + (write ? "Files.ReadWrite" : "Files.Read")]
        case .outlook: values = ["https://graph.microsoft.com/" + (write ? "Mail.ReadWrite" : "Mail.ReadBasic")]
        case .dropbox: values = ["files.metadata.read"] + (write ? ["files.content.write"] : [])
        }
        if persistentConnection && provider.serviceFamily == "microsoft" { values.append("offline_access") }
        return values
    }
    public var isGoogleLoopback: Bool {
        guard provider.serviceFamily == "google", let uri = URLComponents(string: redirectURI) else { return false }
        return uri.scheme?.lowercased() == "http" && uri.host == "127.0.0.1"
    }
    private var credentialRedirect: String {
        guard isGoogleLoopback, var uri = URLComponents(string: redirectURI) else { return redirectURI }
        uri.port = nil // Ephemeral port changes must not create a different account credential.
        return uri.string ?? redirectURI
    }
    public var credentialKey: String {
        let value = [provider.rawValue, clientID, credentialRedirect, scopes.joined(separator: " "), persistentConnection ? "persistent" : "session"].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var validationIssue: String? {
        guard !clientID.isEmpty else { return "unconfigured：尚未配置公开 Client ID。" }
        guard clientID.count <= 512, !clientID.contains(where: { $0.isWhitespace || $0.isNewline }) else { return "Client ID 格式不正确。" }
        guard !redirectURI.contains(where: { $0.isWhitespace || $0.isNewline }), let u = URLComponents(string: redirectURI), let scheme = u.scheme?.lowercased(), !scheme.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, !u.path.isEmpty else { return "回调URI格式不正确；不能包含凭证、查询或fragment。" }
        if scheme == "http" {
            let allowedPath = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
            guard isGoogleLoopback, (0...65535).contains(u.port ?? 0), u.path.hasPrefix("/oauth/"), u.path.count <= 256,
                  u.percentEncodedPath == u.path, u.path.unicodeScalars.allSatisfy({ allowedPath.contains($0) }),
                  !u.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return "本地HTTP回调仅限Google、literal 127.0.0.1和/oauth/路径；不允许localhost、LAN或通配监听。" }
            return nil
        }
        guard !["https","file","javascript","data"].contains(scheme), u.port == nil else { return "仅支持Google本地loopback或已注册的原生自定义回调。" }
        if provider.serviceFamily == "google" && !scheme.contains(".") { return "Google原生自定义scheme必须包含点号；Desktop客户端建议使用本地loopback。" }
        return nil
    }
    public static func suggestedRedirect(provider: ConnectedProvider, clientID: String) -> String {
        if provider.serviceFamily == "google" { return "http://127.0.0.1:0/oauth/" + provider.rawValue }
        return "aiyouclean://oauth/" + provider.serviceFamily
    }
}
public enum ConnectedError: LocalizedError, Equatable {
    case unconfigured, invalidConfiguration, randomFailure, invalidCallback, stateMismatch, expiredAuthorization, authorizationDenied, cancelled, network, invalidResponse, http(Int), missingAuthorization, insufficientScope, unsafeURL, staleSelection, missingConfirmation, expiredPlan, limitReached, loopbackUnavailable, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .unconfigured: return "unconfigured：请先配置公开 Client ID 和已注册回调 URI。"
        case .invalidConfiguration: return "公开客户端配置不正确，或回调 URI 不属于支持的原生流程。"
        case .randomFailure: return "无法取得系统安全随机数，授权已停止。"
        case .invalidCallback: return "授权回调不匹配、含重复参数或含不允许的 token 参数。"
        case .stateMismatch: return "授权 state 校验失败，未交换凭证。"
        case .expiredAuthorization: return "授权请求已过期，请重新连接。"
        case .authorizationDenied: return "服务商未完成授权。没有读取账户数据。"
        case .cancelled: return "已取消授权或网络操作。"
        case .network: return "网络请求未完成。未输出响应正文、token 或邮件内容。"
        case .invalidResponse: return "服务商响应缺少必要字段或超出允许大小。"
        case .http(let status): return "服务商返回 HTTP \(status)。请核对授权范围、账户策略或稍后重试。"
        case .missingAuthorization: return "未连接或凭证已过期，请重新授权。"
        case .insufficientScope: return "当前连接为只读或缺少所需范围。请明确选择列表与回收后重新授权。"
        case .unsafeURL: return "已拒绝不属于对应服务商 API 的地址或不可信分页链接。"
        case .staleSelection: return "选择项目已变化或不属于本次列表，请刷新列表重新选择。"
        case .missingConfirmation: return "尚未确认具体待回收项目。"
        case .expiredPlan: return "回收确认已过期或已使用，请重新检查选择。"
        case .limitReached: return "已达到本次列表或批次上限，请缩小范围。"
        case .loopbackUnavailable: return "无法建立仅本机可访问的临时授权监听；未改用公网或常驻端口。"
        case .keychain(let code): return "系统钥匙串操作失败（\(code)）；未使用明文存储回退。"
        }
    }
}
public struct ConnectedToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scopes: [String]
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date, scopes: [String]) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.scopes = scopes
    }
}
public struct ConnectedItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ConnectedProvider
    public let name: String
    public let location: String
    public let detail: String
    public let bytes: Int64
    public let version: String
    public let canRecycle: Bool
    public let isContainer: Bool
    public init(id: String, provider: ConnectedProvider, name: String, location: String, detail: String, bytes: Int64 = 0, version: String, canRecycle: Bool, isContainer: Bool = false) {
        self.id = id; self.provider = provider; self.name = String(name.prefix(2048)); self.location = String(location.prefix(4096)); self.detail = String(detail.prefix(4096)); self.bytes = bytes; self.version = version; self.canRecycle = canRecycle; self.isContainer = isContainer
    }
}
public struct ConnectedPage: Sendable {
    public let items: [ConnectedItem]
    public let nextCursor: String?
    public let scopeDescription: String
}
public struct ConnectedRecyclePlan: Identifiable, Sendable {
    public let id: UUID
    public let provider: ConnectedProvider
    public let items: [ConnectedItem]
    public let expiresAt: Date
}
public struct ConnectedRecycleOutcome: Sendable {
    public let recycledIDs: [String]
    public let failures: [String]
}
public struct ConnectedHTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol ConnectedTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ConnectedHTTPResult
}
public protocol ConnectedTokenStore: Sendable {
    func read(key: String) throws -> ConnectedToken?
    func write(_ token: ConnectedToken, key: String) throws
    func remove(key: String) throws
}
