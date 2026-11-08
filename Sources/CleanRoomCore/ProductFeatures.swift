import Foundation

/// Product entry policy, independent of runtime file permissions or optional ClamAV availability.
/// `available` means the feature has a supported product entry, not that a scan was run successfully.
public struct ProductFeatureInfo: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let available: Bool
    public let hiddenReason: String?
    public init(id: String, title: String, available: Bool, hiddenReason: String? = nil) {
        self.id = id; self.title = title; self.available = available; self.hiddenReason = hiddenReason
    }
}

public enum ProductFeatures {
    public static var availableScanKinds: [ScanKind] {
        [.cleanup, .largeFiles, .duplicates, .similarImages, .applications, .leftovers, .spaceLens, .protection, .aiModels, .mailAttachments, .downloads]
    }
    private static let policy: [ProductFeatureInfo] = [
        .init(id: "dashboard", title: "总览", available: true),
        .init(id: "smartCare", title: "智能检查", available: true),
        .init(id: "cleanup", title: "本地垃圾清理", available: true),
        .init(id: "advancedCleanup", title: "高级清理", available: true),
        .init(id: "largeFiles", title: "大文件与旧文件", available: true),
        .init(id: "duplicates", title: "重复文件", available: true),
        .init(id: "similarImages", title: "相似图片候选", available: true),
        .init(id: "applications", title: "应用卸载", available: true),
        .init(id: "leftovers", title: "应用残留", available: true),
        .init(id: "spaceLens", title: "空间导航", available: true),
        .init(id: "protection", title: "系统安全状态（只读）", available: true),
        .init(id: "aiModels", title: "本地AI模型", available: true),
        .init(id: "mailAttachments", title: "本地邮件附件", available: true),
        .init(id: "downloads", title: "下载文件", available: true),
        .init(id: "malware", title: "ClamAV恶意软件检测", available: true),
        .init(id: "maintenance", title: "系统维护任务", available: true),
        .init(id: "monitor", title: "系统监控", available: true),
        .init(id: "history", title: "清理历史", available: true),
        .init(id: "browserPrivacy", title: "浏览器本地隐私", available: true),
        .init(id: "preferences", title: "设置与忽略清单", available: true),
        .init(id: "about", title: "关于AIYOUClean", available: true),
        .init(id: "connections", title: "云盘与邮箱连接", available: false, hiddenReason: "缺少生产客户端注册、真实账户授权与远端回收恢复验收；保留实现与既有配置，隐藏产品入口。"),
        .init(id: "cloud", title: "云存储目录", available: false, hiddenReason: "本地同步目录扫描不等同于云端完整存储管理，当前不提供该产品入口。"),
        .init(id: "updates", title: "应用更新", available: false, hiddenReason: "尚无完整生产软件目录和安装回归覆盖；保留后端实现，隐藏产品入口。"),
        .init(id: "screenCleaning", title: "屏幕清洁", available: false, hiddenReason: "仅黑色窗口遮罩，未提供完整输入隔离和屏幕清洁能力。"),
        .init(id: "systemPermissions", title: "系统权限管理", available: false, hiddenReason: "系统设置跳转不等于独立权限管理，不作为功能入口提供。"),
        .init(id: "startup", title: "登录与后台项目", available: false, hiddenReason: "用户LaunchAgent会话操作与完整系统登录/后台项目管理并不等价，当前隐藏入口。"),
        .init(id: "coverageDetails", title: "功能覆盖与限制", available: false, hiddenReason: "开发审阅信息保留在交付文档；产品仅保留简洁关于页。")
    ]
    public static var features: [ProductFeatureInfo] { policy }
    public static var availableFeatures: [ProductFeatureInfo] { policy.filter(\.available) }
    public static var hiddenReasons: [String: String] {
        Dictionary(uniqueKeysWithValues: policy.compactMap { feature in
            guard !feature.available, let reason = feature.hiddenReason else { return nil }
            return (feature.id, reason)
        })
    }
    public static func allows(_ kind: ScanKind) -> Bool { availableScanKinds.contains(kind) }
    public static func isAvailable(_ identifier: String) -> Bool { policy.first { $0.id == identifier }?.available == true }
    public static func title(for kind: ScanKind) -> String { policy.first { $0.id == kind.rawValue }?.title ?? kind.title }
}
