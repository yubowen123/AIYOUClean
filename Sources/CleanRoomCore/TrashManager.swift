import Foundation
import AppKit

public struct TrashOutcome: Sendable {
    public var records: [TrashRecord]
    public var errors: [String]
}
public struct TrashHistoryCursor: Sendable {
    public let date: Date
    public let id: UUID
    public init(_ record: TrashRecord) { date = record.date; id = record.id }
}
public enum TrashError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case .rejected(let reason) = self { return reason }; return nil }
}
public final class TrashManager {
    private let fm = FileManager.default
    private let storageURL: URL
    private let home: URL
    private let lock = NSLock()
    public private(set) var historyWarning: String?
    private let legacyPaths: [URL]
    /// An injectable trash directory is available only for isolated tests; production uses macOS Trash.
    private let testTrash: URL?
    public init(storageURL: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser, testTrash: URL? = nil) {
        self.home = home; self.testTrash = testTrash
        self.storageURL = storageURL ?? home.appendingPathComponent("Library/Application Support/AIYOUClean/trash-history.sqlite3")
        self.legacyPaths = storageURL == nil ? [home.appendingPathComponent("Library/Application Support/AIYOUClean/trash-history.json"), home.appendingPathComponent("Library/Application Support/CleanRoomMac/trash-history.json")] : []
    }
    private func store() throws -> SQLiteHistoryStore {
        let database = try SQLiteHistoryStore(url: storageURL)
        historyWarning = try database.migrateLegacy(legacyPaths)
        return database
    }
    public func records(limit: Int = 200, before: TrashHistoryCursor? = nil, after: TrashHistoryCursor? = nil) -> [TrashRecord] {
        lock.lock(); defer { lock.unlock() }
        do { return try store().records(limit: limit, before: before, after: after) }
        catch { historyWarning = "清理历史读取失败：" + error.localizedDescription; return [] }
    }
    private func validate(_ item:ScanItem) throws -> URL {
        let u = URL(fileURLWithPath:item.path).standardizedFileURL
        guard item.canTrash, let root = item.scopeRoot, item.identity != nil else { throw TrashError.rejected("此项目未被扫描标记为可清理") }
        guard u.path != root, FileSafety.contains(root,u.path), !FileSafety.isProtected(u,home:home), !FileSafety.hasSymlinkComponent(u) else { throw TrashError.rejected("拒绝受保护、越界或符号链接路径") }
        guard !FileSafety.contains(storageURL.deletingLastPathComponent().path,u.path), !FileSafety.contains(u.path,storageURL.path) else { throw TrashError.rejected("不能清理自身历史记录") }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        guard u.path != bundlePath, !FileSafety.contains(u.path,bundlePath) else { throw TrashError.rejected("不能清理当前运行程序") }
        guard FileSafety.identity(u) == item.identity else { throw TrashError.rejected("文件在扫描后发生变化，请重新扫描") }
        if let keeper = item.retainedPath {
            let keptURL = URL(fileURLWithPath:keeper)
            guard keeper != u.path, !FileSafety.hasSymlinkComponent(keptURL), item.retainedIdentity != nil, FileSafety.identity(keptURL) == item.retainedIdentity else {
                throw TrashError.rejected("该组保留项已移走或发生变化，请重新扫描")
            }
        }
        var bundleID: String? = item.group
        if u.pathExtension == "app" { bundleID = Bundle(url:u)?.bundleIdentifier }
        if let bundleID = bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).isEmpty { throw TrashError.rejected("所属应用正在运行，请先退出") }
        return u
    }
    public func trash(_ items:[ScanItem], isCancelled: @Sendable () -> Bool = { false }) -> TrashOutcome {
        lock.lock(); defer { lock.unlock() }
        var result = TrashOutcome(records:[],errors:[])
        guard let permit = WorkBudget.tryAcquire("文件移到废纸篓") else { result.errors.append("另一个重操作正在运行"); return result }
        defer { permit.release() }
        guard items.count <= 5000 else { result.errors.append("单次最多处理5000项，请分批核对"); return result }
        let ignored: [String]
        do { ignored = try IgnoreRuleStore(home: home).load() }
        catch { result.errors.append("忽略清单读取失败，未处理任何项目：" + error.localizedDescription); return result }
        let history: SQLiteHistoryStore
        do { history = try store() } catch { result.errors.append("无法写入恢复记录：\(error.localizedDescription)"); return result }
        var seen = Set<String>()
        let selected = items.filter { seen.insert($0.path).inserted }
        // Refuse ambiguous ancestor/descendant selections rather than silently discarding either selection.
        let paths = Set(selected.map(\.path))
        var overlapping = Set<String>()
        for item in selected {
            autoreleasepool {
                var parent = URL(fileURLWithPath: item.path).deletingLastPathComponent()
                while parent.path != "/" {
                    if paths.contains(parent.path) { overlapping.insert(item.path); overlapping.insert(parent.path) }
                    parent.deleteLastPathComponent()
                }
            }
        }
        for item in selected {
            if isCancelled() { result.errors.append("已取消，未开始的项目保持原位"); break }
            do {
                if overlapping.contains(item.path) { throw TrashError.rejected("选择包含父目录与子文件，请只保留一层") }
                if IgnoreRuleStore.isExcluded(item.path, by: ignored) || ignored.contains(where: { FileSafety.contains(item.path, $0) }) {
                    throw TrashError.rejected("该项目或其子项在当前忽略清单中，请重新扫描")
                }
                let u = try validate(item)
                let parentIdentity = FileSafety.identity(u.deletingLastPathComponent())
                let destination: URL
                if let testTrash = testTrash {
                    guard !FileSafety.hasSymlinkComponent(testTrash) else { throw TrashError.rejected("测试废纸篓不可为符号链接") }
                    try fm.createDirectory(at:testTrash,withIntermediateDirectories:true)
                    destination = testTrash.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent)
                    try fm.moveItem(at:u,to:destination)
                } else {
                    var resulting: NSURL?
                    try fm.trashItem(at:u,resultingItemURL:&resulting)
                    guard let actual = resulting as URL? else { throw TrashError.rejected("系统未返回废纸篓位置；请在 Finder 核对") }
                    destination = actual
                }
                let record = TrashRecord(originalPath:u.path,trashPath:destination.path,bytes:item.bytes,originalParentIdentity:parentIdentity,trashIdentity:FileSafety.identity(destination))
                do { try history.insert(record) }
                catch {
                    // Roll back the move if the receipt cannot be saved.
                    if !fm.fileExists(atPath:u.path) { try? fm.moveItem(at:destination,to:u) }
                    throw TrashError.rejected("恢复记录保存失败，已尝试撤回：\(error.localizedDescription)")
                }
                result.records.append(record)
            } catch { if result.errors.count < 100 { result.errors.append("\(item.name)：\(error.localizedDescription)") } }
        }
        return result
    }
    public func restore(_ record:TrashRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard let permit = WorkBudget.tryAcquire("恢复废纸篓文件") else { throw TrashError.rejected("另一个重操作正在运行") }
        defer { permit.release() }
        let history = try store()
        guard let saved = try history.find(record.id), saved.trashPath == record.trashPath, saved.originalPath == record.originalPath else { throw TrashError.rejected("找不到匹配的恢复记录") }
        let source = URL(fileURLWithPath:record.trashPath).standardizedFileURL
        let dest = URL(fileURLWithPath:record.originalPath).standardizedFileURL
        guard source.path != dest.path, !FileSafety.hasSymlinkComponent(source), !FileSafety.hasSymlinkComponent(dest), !FileSafety.isProtected(dest,home:home), !fm.fileExists(atPath:dest.path) else { throw TrashError.rejected("恢复路径受保护、包含链接或原位置已有同名文件") }
        guard fm.fileExists(atPath:dest.deletingLastPathComponent().path) else { throw TrashError.rejected("原目录已不存在，请在 Finder 手动恢复") }
        guard let expectedSource = record.trashIdentity, FileSafety.identity(source) == expectedSource else {
            throw TrashError.rejected("废纸篓中的项目已变化，不能按旧记录恢复")
        }
        guard let expectedParent = record.originalParentIdentity, let actualParent = FileSafety.identity(dest.deletingLastPathComponent()), expectedParent.device == actualParent.device, expectedParent.inode == actualParent.inode else {
            throw TrashError.rejected("原父目录身份已改变，请在 Finder 核对后手动恢复")
        }
        try fm.moveItem(at:source,to:dest)
        do { try history.remove(record.id) }
        catch {
            try? fm.moveItem(at:dest,to:source)
            throw TrashError.rejected("更新恢复记录失败，已尝试撤回恢复：\(error.localizedDescription)")
        }
    }
}
