import Foundation

public enum ScanKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cleanup, largeFiles, duplicates, similarImages, applications, leftovers, startup, spaceLens, cloud, protection, aiModels, mailAttachments, downloads
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cleanup: return "垃圾清理"
        case .largeFiles: return "大文件与旧文件"
        case .duplicates: return "重复文件"
        case .similarImages: return "相似图片"
        case .applications: return "应用程序"
        case .leftovers: return "应用残留"
        case .startup: return "登录与后台项目"
        case .spaceLens: return "空间透镜"
        case .cloud: return "云存储本地文件"
        case .protection: return "安全状态检查"
        case .aiModels: return "AI 本地模型"
        case .mailAttachments: return "邮件附件"
        case .downloads: return "下载文件"
        }
    }
    public var symbol: String {
        switch self {
        case .cleanup: return "sparkles"
        case .largeFiles: return "doc.zipper"
        case .duplicates: return "doc.on.doc"
        case .similarImages: return "photo.on.rectangle.angled"
        case .applications: return "square.grid.2x2"
        case .leftovers: return "shippingbox"
        case .startup: return "power"
        case .spaceLens: return "chart.pie"
        case .cloud: return "icloud"
        case .protection: return "shield.lefthalf.filled"
        case .aiModels: return "cpu"
        case .mailAttachments: return "envelope"
        case .downloads: return "arrow.down.circle"
        }
    }
    public var detail: String {
        switch self {
        case .cleanup: return "检查用户缓存、日志与 Xcode DerivedData；扫描后逐项选择。"
        case .largeFiles: return "查找至少 100 MB 或一年未修改的文件。"
        case .duplicates: return "先按大小分组，再逐块计算 SHA-256。每组保留一份。"
        case .similarImages: return "用图片差异哈希查找视觉近似项；压缩、裁剪和语义相似可能漏检。"
        case .applications: return "读取已安装应用及精确 bundle ID 对应的支持文件。"
        case .leftovers: return "检查没有对应已安装应用的缓存和偏好候选；需要人工核对。"
        case .startup: return "列出用户与系统 LaunchAgents / LaunchDaemons；跳转系统设置管理。"
        case .spaceLens: return "统计目录大小，查看磁盘空间分布。"
        case .cloud: return "只统计已同步到本机的云文件；不访问云端 API、不下载占位文件。"
        case .protection: return "查看 Gatekeeper、SIP、FileVault 与防火墙状态；这不是恶意软件扫描。"
        case .aiModels: return "查看 Ollama、Hugging Face、LM Studio 的本地模型占用。"
        case .mailAttachments: return "查找 Mail 下载附件；受 macOS 文件访问权限限制。"
        case .downloads: return "浏览下载目录中的文件与安装包。"
        }
    }
}

public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modified: Double
    public init(device: UInt64, inode: UInt64, size: Int64, modified: Double) {
        self.device = device; self.inode = inode; self.size = size; self.modified = modified
    }
}

public struct ScanItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let category: String
    public let bytes: Int64
    public let detail: String
    public let group: String?
    public let canTrash: Bool
    public let identity: FileIdentity?
    public let scopeRoot: String?
    public let retainedPath: String?
    public let retainedIdentity: FileIdentity?
    public init(path: String, name: String? = nil, category: String, bytes: Int64 = 0, detail: String = "", group: String? = nil, canTrash: Bool = false, identity: FileIdentity? = nil, scopeRoot: String? = nil, retainedPath: String? = nil, retainedIdentity: FileIdentity? = nil) {
        self.id = category + ":" + path; self.path = path; self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.category = category; self.bytes = bytes; self.detail = detail; self.group = group; self.canTrash = canTrash; self.identity = identity; self.scopeRoot = scopeRoot; self.retainedPath = retainedPath; self.retainedIdentity = retainedIdentity
    }
}

public enum ScanStopReason: String, Codable, Sendable {
    case fileLimit, timeLimit, memoryLimit, resultLimit, cancelled, busy, configurationError, storageError
    public var title: String {
        switch self {
        case .fileLimit: return "已达到本次文件数量上限"
        case .timeLimit: return "已达到本次扫描时长上限"
        case .memoryLimit: return "已达到进程内存保护阈值"
        case .resultLimit: return "结果列表已达到保留上限"
        case .cancelled: return "扫描已取消"
        case .busy: return "另一项重操作正在运行"
        case .configurationError: return "扫描配置无法读取"
        case .storageError: return "扫描结果无法写入磁盘"
        }
    }
}

public struct ScanReport: Codable, Sendable {
    public let kind: ScanKind
    public let startedAt: Date
    public var finishedAt: Date
    public var items: [ScanItem]
    public var warnings: [String]
    public var visitedFiles: Int
    public var truncated: Bool
    public var peakResidentBytes: UInt64? = nil
    public var memoryBudgetBytes: UInt64? = nil
    public var resultLimit: Int? = nil
    public var stopReason: ScanStopReason? = nil
    public var fileLimit: Int? = nil
    public var timeLimitSeconds: Double? = nil
    public var resultStore: ScanResultReference? = nil
    public var totalItemCount: Int? = nil
    public var processableItemCount: Int? = nil
    public var allItemsBytes: Int64? = nil
    public var totalBytes: Int64 { allItemsBytes ?? items.reduce(0) { $0 + $1.bytes } }
    public init(kind: ScanKind, startedAt: Date = Date(), items: [ScanItem] = [], warnings: [String] = [], visitedFiles: Int = 0, truncated: Bool = false, stopReason: ScanStopReason? = nil) {
        self.kind = kind; self.startedAt = startedAt; self.finishedAt = Date(); self.items = items; self.warnings = warnings; self.visitedFiles = visitedFiles; self.truncated = truncated
        self.stopReason = stopReason
    }
}

public struct ScanOptions: Sendable {
    public var home: URL
    public var roots: [URL]
    public var maxFiles: Int
    public var maxSeconds: TimeInterval
    public var largeFileBytes: Int64
    public var maxResults: Int
    public var memoryBudgetBytes: UInt64
    public var excludedPaths: [String]
    /// Production scans persist results and run until completion or cancellation.
    /// false is an explicitly bounded diagnostic scan, never a GUI default.
    public var scanToCompletion: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, roots: [URL] = [], maxFiles: Int = 100_000, maxSeconds: TimeInterval = 180, largeFileBytes: Int64 = 100_000_000, maxResults: Int = 5000, memoryBudgetBytes: UInt64 = 512 * 1024 * 1024, excludedPaths: [String] = [], scanToCompletion: Bool = true) {
        self.home = home; self.roots = roots; self.maxFiles = maxFiles; self.maxSeconds = maxSeconds; self.largeFileBytes = largeFileBytes; self.maxResults = min(30_000, max(1, maxResults)); self.memoryBudgetBytes = max(32 * 1024 * 1024, memoryBudgetBytes)
        self.excludedPaths = excludedPaths; self.scanToCompletion = scanToCompletion
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

public struct TrashRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let originalPath: String
    public let trashPath: String
    public let bytes: Int64
    public let originalParentIdentity: FileIdentity?
    public let trashIdentity: FileIdentity?
    public init(originalPath: String, trashPath: String, bytes: Int64, originalParentIdentity: FileIdentity? = nil, trashIdentity: FileIdentity? = nil) {
        id = UUID(); date = Date(); self.originalPath = originalPath; self.trashPath = trashPath; self.bytes = bytes
        self.originalParentIdentity = originalParentIdentity; self.trashIdentity = trashIdentity
    }
}

public struct SystemSnapshot: Sendable {
    public let host: String
    public let os: String
    public let totalDisk: Int64
    public let availableDisk: Int64
    public let totalMemory: UInt64
    public let processors: Int
    public let uptime: TimeInterval
    public let loadAverage: String
    public let battery: String
}
