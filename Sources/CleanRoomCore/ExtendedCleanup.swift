import Foundation
import CryptoKit
import Darwin

public enum ExtendedCleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case brokenPreferences, developerCaches, aiCaches, iOSBackups
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .brokenPreferences: return "损坏偏好文件候选"
        case .developerCaches: return "开发工具缓存"
        case .aiCaches: return "AI工具缓存"
        case .iOSBackups: return "iPhone与iPad备份"
        }
    }
}
public struct ExtendedCleanupOptions: Sendable {
    public var home: URL
    public var maxFiles: Int
    public var maxResults: Int
    public var maxSeconds: TimeInterval
    public var scanToCompletion: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, maxFiles: Int = 50_000, maxResults: Int = 200, maxSeconds: TimeInterval = 120, scanToCompletion: Bool = true) {
        self.home = home; self.maxFiles = max(1, maxFiles); self.maxResults = min(200, max(1, maxResults)); self.maxSeconds = max(0.01, maxSeconds); self.scanToCompletion = scanToCompletion
    }
}
public struct ExtendedCleanupReport: Sendable {
    public var items: [ScanItem] = []
    public var warnings: [String] = []
    public var visitedFiles = 0
    public var truncated = false
    public var cancelled = false
    public var resultStore: ScanResultReference?
    public var totalCount = 0
    public var processableCount = 0
    public var totalBytes: Int64 = 0
}
public enum ExtendedCleanupError: LocalizedError {
    case rejected(String), cancelled
    public var errorDescription: String? {
        switch self { case .rejected(let reason): return reason; case .cancelled: return "操作已取消或诊断检查未完成。" }
    }
}
private struct ExtendedTreeSummary {
    var bytes: Int64 = 0
    var fingerprint = ""
    var complete = true
}
private final class ExtendedWalk {
    let options: ExtendedCleanupOptions, cancellation: MalwareCancellation
    let progress: @Sendable (Int, String) -> Void
    let deadline: TimeInterval
    var visited = 0, warnings: [String] = []
    var truncated = false
    var storageFailure: String?
    var ignored: [String] = []
    init(_ options: ExtendedCleanupOptions, _ cancellation: MalwareCancellation, _ progress: @escaping @Sendable (Int, String) -> Void = {_,_ in}) {
        self.options = options; self.cancellation = cancellation; self.progress = progress
        deadline = ProcessInfo.processInfo.systemUptime + options.maxSeconds
    }
    func warn(_ text: String) { if warnings.count < 100, !warnings.contains(text) { warnings.append(text) } }
    var stopped: Bool {
        if cancellation.isCancelled { return true }
        if storageFailure != nil { truncated = true; return true }
        if !options.scanToCompletion && (visited >= options.maxFiles || ProcessInfo.processInfo.systemUptime >= deadline) { truncated = true; return true }
        return false
    }
    func step(_ path: String) -> Bool {
        if stopped { return false }
        visited += 1; if visited % 100 == 0 { progress(visited, path) }; return true
    }
    func safeStat(_ url: URL) -> stat? {
        guard !IgnoreRuleStore.isExcluded(url.path, by: ignored) else { return nil }
        var st = stat()
        guard !FileSafety.hasSymlinkComponent(url), lstat(url.path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0 else { truncated = true; warn("已跳过链接、云占位或不可读路径：\(url.path)"); return nil }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { truncated = true; warn("已跳过特殊文件：\(url.path)"); return nil }
        return st
    }
    // Entire nextObject and metadata work is within the pool; no prefetched NSURL resources.
    func children(_ root: URL, _ body: (URL) -> Void) {
        guard !stopped, safeStat(root) != nil else { return }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { [self] u,e in truncated = true; warn("无法读取\(u.path)：\(e.localizedDescription)"); return !stopped }) else { truncated = true; warn("无法枚举：\(root.path)"); return }
        var exhausted = false
        while !exhausted && !stopped {
            autoreleasepool {
                guard let url = enumerator.nextObject() as? URL else { exhausted = true; return }
                guard !IgnoreRuleStore.isExcluded(url.path, by: ignored) else { return }
                body(url)
            }
        }
    }
    func summary(_ root: URL) -> ExtendedTreeSummary {
        var result = ExtendedTreeSummary(), digest = [UInt8](repeating: 0, count: 32), entries = 0
        func add(_ url: URL) {
            guard step(url.path), let st = safeStat(url) else { result.complete = false; return }
            let relative = String(url.path.dropFirst(root.path.count))
            let text = "\(relative)|\(st.st_dev)|\(st.st_ino)|\(st.st_mode)|\(st.st_size)|\(st.st_mtimespec.tv_sec)|\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec)|\(st.st_ctimespec.tv_nsec)"
            let hash = Array(SHA256.hash(data: Data(text.utf8))); for i in 0..<32 { digest[i] ^= hash[i] }; entries += 1
            if st.st_mode & S_IFMT == S_IFREG { result.bytes += max(0, Int64(st.st_size)) }
        }
        guard let metadata = safeStat(root) else { result.complete = false; return result }
        add(root)
        if metadata.st_mode & S_IFMT == S_IFDIR {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { [self] u,e in result.complete = false; warn("无法读取\(u.path)：\(e.localizedDescription)"); return true })
            var exhausted = enumerator == nil
            while !exhausted && !stopped {
                autoreleasepool {
                    guard let url = enumerator?.nextObject() as? URL else { exhausted = true; return }
                    if IgnoreRuleStore.isExcluded(url.path, by: ignored) { enumerator?.skipDescendants(); result.complete = false; return }
                    if FileSafety.isSymbolicLink(url) { enumerator?.skipDescendants() }
                    var st = stat()
                    if lstat(url.path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) != 0 { enumerator?.skipDescendants() }
                    add(url)
                }
            }
            if !exhausted { result.complete = false }
        }
        if stopped { result.complete = false }
        result.fingerprint = digest.map { String(format: "%02x", $0) }.joined() + ":\(entries)"
        return result
    }
}

public final class ExtendedCleanupScanner {
    public init() {}
    public func scan(_ category: ExtendedCleanupCategory, options: ExtendedCleanupOptions = ExtendedCleanupOptions(), cancellation: MalwareCancellation = MalwareCancellation(), progress: @escaping @Sendable (Int, String) -> Void = {_,_ in}) -> ExtendedCleanupReport {
        var report = ExtendedCleanupReport()
        guard let permit = WorkBudget.tryAcquire("高级清理扫描") else { report.truncated = true; report.warnings = ["另一个重型操作正在运行，未开始扫描。"]; return report }
        defer { permit.release() }
        let work = ExtendedWalk(options, cancellation, progress)
        do { work.ignored = try IgnoreRuleStore(home: options.home).load() }
        catch { report.truncated = true; report.warnings = ["忽略清单读取失败，未开始扫描：" + error.localizedDescription]; return report }
        let store: ScanResultStore
        do { store = try ScanResultStore.createTemporary(); report.resultStore = store.reference }
        catch { report.truncated = true; report.warnings = ["无法建立高级清理落盘结果：" + error.localizedDescription]; return report }
        func append(_ item: ScanItem) {
            do { try store.append(item) }
            catch { work.storageFailure = "结果无法继续落盘，已保留提交部分：" + error.localizedDescription; work.warn(work.storageFailure!) }
        }
        let locations: [(String, String)]
        switch category {
        case .brokenPreferences: locations = [("Library/Preferences", "偏好文件")]
        case .developerCaches: locations = [("Library/Developer/Xcode/DerivedData", "Xcode派生数据"), ("Library/Developer/CoreSimulator/Caches", "模拟器缓存"), (".npm/_cacache", "npm缓存"), ("Library/Caches/pip", "pip缓存"), (".cache/pip", "pip缓存"), ("Library/Caches/Homebrew", "Homebrew下载缓存")]
        case .aiCaches: locations = [(".cache/huggingface", "Hugging Face缓存/模型"), (".cache/torch", "PyTorch缓存/模型"), ("Library/Caches/com.openai.chat", "ChatGPT缓存"), (".cache/lm-studio", "LM Studio缓存")]
        case .iOSBackups: locations = [("Library/Application Support/MobileSync/Backup", "iOS本地备份")]
        }
        for (relative, label) in locations {
            if work.stopped { break }
            let root = options.home.appendingPathComponent(relative).standardizedFileURL
            if !FileManager.default.fileExists(atPath: root.path) { continue }
            work.children(root) { url in
                guard !work.stopped, let metadata = work.safeStat(url) else { return }
                if category == .brokenPreferences {
                    guard url.pathExtension.lowercased() == "plist", metadata.st_mode & S_IFMT == S_IFREG, work.step(url.path) else { return }
                    guard metadata.st_size <= 4_000_000 else { work.truncated = true; work.warn("偏好文件超过4MB，未解析：\(url.path)"); return }
                    do {
                        let fd = try MalwareFiles.openRegular(url); let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        let data = try handle.read(upToCount: 4_000_001) ?? Data()
                        guard data.count <= 4_000_000, FileSafety.identity(url) == MalwareFiles.identity(metadata) else { work.truncated = true; work.warn("偏好文件已变化，已跳过：\(url.path)"); return }
                        do { _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
                        catch {
                            append(ScanItem(path: url.path, category: label, bytes: Int64(data.count), detail: "系统plist解析失败；仅是损坏候选，处理会重置该应用偏好。", canTrash: true, identity: FileSafety.identity(url), scopeRoot: root.path))
                        }
                    } catch { work.truncated = true; work.warn("无法解析\(url.path)：\(error.localizedDescription)") }
                } else {
                    let summary = work.summary(url)
                    var detail = category == .iOSBackups ? "设备完整备份，不是缓存；移走后无法从本机使用此备份。" : "可重新生成或重新下载的数据；应用使用中可能重新创建。"
                    if category == .aiCaches { detail = "可能包含大型模型资产，移走后相关工具可能需要重新下载。" }
                    if !summary.complete { work.truncated = true; detail += "占用统计未完成，当前不可处理。" }
                    let includesIgnored = work.ignored.contains { FileSafety.contains(url.path, $0) }
                    if includesIgnored { detail += "包含忽略项目，不能整体清理。" }
                    append(ScanItem(path: url.path, category: label, bytes: summary.bytes, detail: detail, canTrash: summary.complete && !includesIgnored && !FileSafety.isProtected(url, home: options.home), identity: FileSafety.identity(url), scopeRoot: root.path))
                }
            }
        }
        do {
            try store.flush(); let page = try store.page(limit: options.maxResults, largestFirst: false)
            report.items = page.items; report.totalCount = page.statistics.totalCount
            report.processableCount = page.statistics.processableCount; report.totalBytes = page.statistics.totalBytes
        } catch { work.truncated = true; work.warn("部分落盘结果无法读取：" + error.localizedDescription) }
        report.visitedFiles = work.visited; report.warnings = work.warnings; report.cancelled = cancellation.isCancelled
        report.truncated = work.truncated || report.cancelled
        if report.truncated && !options.scanToCompletion { report.warnings.append("诊断检查或部分路径未完成；仅覆盖已检查范围。") }
        if report.cancelled { report.warnings.append("扫描已取消，结果不完整。") }
        return report
    }
}

public struct TrashInspectionItem: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String, trashRoot: String, fingerprint: String
    public let bytes: Int64
    public let identity: FileIdentity, rootIdentity: FileIdentity
    public let canPermanentlyDelete: Bool
}
public struct TrashInspectionReport: Sendable {
    public var items: [TrashInspectionItem] = []
    public var warnings: [String] = []
    public var visitedFiles = 0
    public var truncated = false
    public var cancelled = false
    public var resultStore: ScanResultReference?
    public var totalCount = 0
    public var processableCount = 0
    public var totalBytes: Int64 = 0
}
public struct TrashDeletionReport: Sendable {
    public var deletedPaths: [String] = []
    public var errors: [String] = []
    public var cancelled = false
}
public final class TrashInspector {
    private let home: URL
    private let volumesRoot: URL
    private let testRoots: [URL]?
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) {
        self.home = home; self.volumesRoot = volumesRoot; testRoots = nil
    }
    init(testRoots: [URL], home: URL) { self.testRoots = testRoots; self.home = home; volumesRoot = home.appendingPathComponent("unused-volumes") }
    private func forEachRoot(_ work: ExtendedWalk, _ body: (URL) -> Void) {
        if let testRoots { for root in testRoots { if work.stopped { break }; body(root) }; return }
        body(home.appendingPathComponent(".Trash"))
        let uid = String(getuid())
        work.children(volumesRoot) { volume in
            guard !work.stopped, !FileSafety.isSymbolicLink(volume) else { return }
            let root = volume.appendingPathComponent(".Trashes/" + uid)
            var metadata = stat()
            if lstat(root.path, &metadata) == 0 { body(root) }
            else if errno != ENOENT { work.truncated = true; work.warn("无法检查卷废纸篓目录（errno \(errno)）：\(root.path)") }
        }
    }
    private func allowedRoot(_ root: URL) -> Bool {
        if let testRoots { return testRoots.contains { $0.standardizedFileURL.path == root.path } }
        if root.path == home.appendingPathComponent(".Trash").standardizedFileURL.path { return true }
        let trash = root.deletingLastPathComponent(), volume = trash.deletingLastPathComponent()
        return root.lastPathComponent == String(getuid()) && trash.lastPathComponent == ".Trashes"
            && volume.deletingLastPathComponent().path == volumesRoot.standardizedFileURL.path
    }
    private func validRoot(_ url: URL) -> Bool {
        var st = stat()
        return !FileSafety.hasSymlinkComponent(url) && lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid()
    }
    public func scan(options: ExtendedCleanupOptions = ExtendedCleanupOptions(), cancellation: MalwareCancellation = MalwareCancellation(), progress: @escaping @Sendable (Int, String) -> Void = {_,_ in}) -> TrashInspectionReport {
        var report = TrashInspectionReport()
        guard let permit = WorkBudget.tryAcquire("废纸篓清点") else { report.truncated = true; report.warnings = ["另一个重型操作正在运行，未开始清点。"]; return report }
        defer { permit.release() }
        let work = ExtendedWalk(options, cancellation, progress)
        let store: TrashInspectionStore
        do { store = try TrashInspectionStore.createTemporary(); report.resultStore = store.reference }
        catch { report.truncated = true; report.warnings = ["无法建立废纸篓清点结果：" + error.localizedDescription]; return report }
        forEachRoot(work) { root in
            guard !work.stopped else { return }
            var metadata = stat()
            guard lstat(root.path, &metadata) == 0 else {
                if errno != ENOENT { work.truncated = true; work.warn("废纸篓目录无法访问（errno \(errno)）：\(root.path)") }
                return
            }
            guard validRoot(root), let rootIdentity = FileSafety.identity(root) else {
                work.truncated = true; work.warn("废纸篓目录不是当前用户拥有或含链接，已跳过：\(root.path)"); return
            }
            work.children(root) { url in
                guard !work.stopped else { return }
                guard let identity = FileSafety.identity(url) else { work.truncated = true; work.warn("项目身份无法读取，未完整检查：\(url.path)"); return }
                let summary = work.summary(url)
                if !summary.complete { work.truncated = true }
                do {
                    try store.append(TrashInspectionItem(path: url.path, trashRoot: root.path, fingerprint: summary.fingerprint, bytes: summary.bytes, identity: identity, rootIdentity: rootIdentity, canPermanentlyDelete: summary.complete))
                } catch { work.storageFailure = "清点结果无法继续落盘：" + error.localizedDescription; work.warn(work.storageFailure!) }
            }
        }
        do {
            try store.flush(); let page = try store.page(limit: options.maxResults)
            report.items = page.items; report.totalCount = page.statistics.totalCount
            report.processableCount = page.statistics.processableCount; report.totalBytes = page.statistics.totalBytes
        } catch { work.truncated = true; work.warn("部分清点结果无法读取：" + error.localizedDescription) }
        report.visitedFiles = work.visited; report.warnings = work.warnings; report.cancelled = cancellation.isCancelled
        report.truncated = work.truncated || report.cancelled
        if report.truncated { report.warnings.append("清点未完成，未完整检查的项目不能永久删除；已完整项目仍需逐项确认。") }
        return report
    }
    public func permanentlyDelete(_ items: [TrashInspectionItem], confirmed: Bool, confirmationPaths: [String], cancellation: MalwareCancellation = MalwareCancellation()) -> TrashDeletionReport {
        var report = TrashDeletionReport()
        guard confirmed, !items.isEmpty, items.count <= 2000, Set(confirmationPaths) == Set(items.map(\.path)), Set(items.map(\.path)).count == items.count else { report.errors = ["必须明确确认这批具体路径，且不能超过2000项或重复。"]; return report }
        guard let permit = WorkBudget.tryAcquire("永久删除已确认废纸篓项目") else { report.errors = ["另一个重型操作正在运行，未执行删除。"]; return report }
        defer { permit.release() }
        let work = ExtendedWalk(ExtendedCleanupOptions(home: home, scanToCompletion: true), cancellation)
        for item in items {
            if work.stopped { report.cancelled = cancellation.isCancelled; report.errors.append("已取消，余下项目未处理。"); break }
            do {
                let root = URL(fileURLWithPath: item.trashRoot).standardizedFileURL, target = URL(fileURLWithPath: item.path).standardizedFileURL
                guard item.canPermanentlyDelete, allowedRoot(root), target.deletingLastPathComponent().path == root.path, target.path != root.path, validRoot(root), !FileSafety.hasSymlinkComponent(target), let rootNow = FileSafety.identity(root), rootNow.device == item.rootIdentity.device, rootNow.inode == item.rootIdentity.inode, FileSafety.identity(target) == item.identity else { throw ExtendedCleanupError.rejected("路径边界或文件身份已变化，拒绝删除。") }
                let current = work.summary(target)
                guard current.complete, current.fingerprint == item.fingerprint else { throw ExtendedCleanupError.rejected("目录内容已变化或未完整检查，请重新清点。") }
                let parent = try MalwareFiles.openDirectory(root); defer { close(parent) }
                try removeEntry(parent: parent, name: target.lastPathComponent, expected: item.identity, work: work)
                var remains = stat()
                guard fstatat(parent, target.lastPathComponent, &remains, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ExtendedCleanupError.rejected("删除后回读仍存在同名项目，未确认删除成功。") }
                report.deletedPaths.append(item.path)
            } catch { if report.errors.count < 100 { report.errors.append("\(item.path)：\(error.localizedDescription)") } }
        }
        report.cancelled = cancellation.isCancelled
        return report
    }
    private func removeEntry(parent: Int32, name: String, expected: FileIdentity?, work: ExtendedWalk) throws {
        guard !work.stopped else { throw ExtendedCleanupError.cancelled }
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_flags & UInt32(SF_DATALESS) == 0, expected == nil || MalwareFiles.identity(st) == expected else { throw ExtendedCleanupError.rejected("删除前身份已变化。") }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw ExtendedCleanupError.rejected("拒绝链接或特殊文件。") }
        guard work.step(name) else { throw ExtendedCleanupError.cancelled }
        if type == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ExtendedCleanupError.rejected("无法安全打开待删目录。") }; defer { close(fd) }
            var opened = stat(); guard fstat(fd, &opened) == 0, MalwareFiles.identity(opened) == MalwareFiles.identity(st) else { throw ExtendedCleanupError.rejected("待删目录已替换。") }
            guard let directory = fdopendir(dup(fd)) else { throw ExtendedCleanupError.rejected("无法枚举待删目录。") }; defer { closedir(directory) }
            while let entry = readdir(directory) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if child == "." || child == ".." { continue }
                try autoreleasepool { try removeEntry(parent: fd, name: child, expected: nil, work: work) }
            }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == st.st_dev, current.st_ino == st.st_ino, unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ExtendedCleanupError.rejected("目录删除失败或出现新内容；可能已有部分删除。") }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw ExtendedCleanupError.rejected("文件删除失败（errno \(errno)）。") }
        }
    }
}

// NSFileVersion promises NSCoding, not NSSecureCoding, for its persistent ID.
// Keep the native identifier process-local and bounded; public descriptors carry
// an opaque short-lived token, never an archive that needs generic decoding.
private final class ExtendedVersionIdentifierCache: @unchecked Sendable {
    static let shared = ExtendedVersionIdentifierCache()
    private struct Entry {
        let identifier: any NSCoding
        let documentPath: String
        let documentDevice: UInt64
        let documentInode: UInt64
        let inserted: TimeInterval
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var ring: [UUID?] = Array(repeating: nil, count: 2000)
    private var next = 0
    func beginList(documentPath: String) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { $0.value.documentPath != documentPath && now - $0.value.inserted < 600 }
    }
    func store(_ identifier: any NSCoding, documentPath: String, identity: FileIdentity) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let evicted = ring[next] { entries.removeValue(forKey: evicted) }
        let token = UUID()
        entries[token] = Entry(identifier: identifier, documentPath: documentPath, documentDevice: identity.device, documentInode: identity.inode, inserted: ProcessInfo.processInfo.systemUptime)
        ring[next] = token; next = (next + 1) % ring.count
        return Data(token.uuidString.utf8)
    }
    func lookup(_ data: Data, documentPath: String, identity: FileIdentity) -> (any NSCoding)? {
        guard data.count == 36, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[token], entry.documentPath == documentPath, entry.documentDevice == identity.device, entry.documentInode == identity.inode, ProcessInfo.processInfo.systemUptime - entry.inserted < 600 else { return nil }
        return entry.identifier
    }
}

public struct DocumentHistoryVersion: Identifiable, Codable, Sendable {
    public var id: String { identifierData.base64EncodedString() }
    public let documentPath: String
    /// Opaque process-local session token (10 minute lifetime), not serialized system data.
    public let identifierData: Data
    public let modifiedAt: Date?
    public let hasLocalContents: Bool
}
public struct DocumentVersionArchiveRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let documentPath: String
    public let documentIdentity: FileIdentity
    public let backupPath: String
    public let sha256: String
    public let bytes: Int64
    public let date: Date
    public var versionRemoved: Bool
    public var restoredAsHistory: Bool
}
public final class DocumentVersionArchive {
    public let root: URL
    public init(root: URL? = nil) { self.root = root ?? ClamAVEngine.applicationSupportDirectory.appendingPathComponent("VersionArchive") }
    public func list(document: URL) throws -> [DocumentHistoryVersion] {
        guard !FileSafety.hasSymlinkComponent(document), let identity = FileSafety.identity(document) else { throw ExtendedCleanupError.rejected("文档不存在或包含链接。") }
        let versions = NSFileVersion.otherVersionsOfItem(at: document) ?? []
        let cache = ExtendedVersionIdentifierCache.shared
        cache.beginList(documentPath: document.path)
        return versions.prefix(2000).map { version in
            autoreleasepool {
                let token = cache.store(version.persistentIdentifier, documentPath: document.path, identity: identity)
                return DocumentHistoryVersion(documentPath: document.path, identifierData: token, modifiedAt: version.modificationDate, hasLocalContents: version.hasLocalContents)
            }
        }
    }
    private func prepareRoot() throws {
        guard !FileSafety.hasSymlinkComponent(root) else { throw ExtendedCleanupError.rejected("归档路径含链接。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat(); guard lstat(root.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw ExtendedCleanupError.rejected("归档目录必须为当前用户拥有的0700目录。") }
    }
    private func save(_ record: DocumentVersionArchiveRecord) throws {
        let url = root.appendingPathComponent(record.id.uuidString).appendingPathComponent("receipt.json")
        guard !FileSafety.hasSymlinkComponent(url) else { throw ExtendedCleanupError.rejected("归档收据路径含链接。") }
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func records() throws -> [DocumentVersionArchiveRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try prepareRoot()
        let work = ExtendedWalk(ExtendedCleanupOptions(maxResults: 2000), MalwareCancellation()); var records: [DocumentVersionArchiveRecord] = []
        var receiptError: String?
        work.children(root) { url in
            guard records.count < 2000, UUID(uuidString: url.lastPathComponent) != nil else { return }
            let receipt = url.appendingPathComponent("receipt.json")
            guard !FileSafety.hasSymlinkComponent(receipt), let identity = FileSafety.identity(receipt), identity.size <= 256_000 else { receiptError = "归档收据缺失、过大或含链接：\(url.path)"; return }
            do {
                let data = try Data(contentsOf: receipt), record = try JSONDecoder().decode(DocumentVersionArchiveRecord.self, from: data)
                guard record.id.uuidString == url.lastPathComponent, record.backupPath == url.appendingPathComponent("contents.archive").path else { throw ExtendedCleanupError.rejected("归档收据路径不匹配。") }
                records.append(record)
            } catch { receiptError = "归档收据读取失败：\(error.localizedDescription)" }
        }
        if let receiptError { throw ExtendedCleanupError.rejected(receiptError) }
        if let warning = work.warnings.first { throw ExtendedCleanupError.rejected(warning) }
        return records
    }
    @discardableResult public func archiveAndRemove(_ version: DocumentHistoryVersion, confirmed: Bool, cancellation: MalwareCancellation = MalwareCancellation()) throws -> DocumentVersionArchiveRecord {
        guard confirmed, version.hasLocalContents else { throw ExtendedCleanupError.rejected("需确认具体本地版本；不下载远端版本。") }
        guard let permit = WorkBudget.tryAcquire("归档文档历史版本") else { throw ExtendedCleanupError.rejected("另一个重型操作正在运行。") }; defer { permit.release() }
        let document = URL(fileURLWithPath: version.documentPath).standardizedFileURL
        guard !FileSafety.hasSymlinkComponent(document), !FileSafety.isProtected(document), let identity = FileSafety.identity(document), identity.size <= 200_000_000 else { throw ExtendedCleanupError.rejected("文档受保护、包含链接或超过200MB处理上限。") }
        let deadlineTimer = operationDeadline(cancellation); defer { deadlineTimer.cancel() }
        try prepareRoot()
        guard let identifier = ExtendedVersionIdentifierCache.shared.lookup(version.identifierData, documentPath: document.path, identity: identity) else { throw ExtendedCleanupError.rejected("版本选择已过期、应用已重启或文档已替换，请重新读取历史列表后再选择。") }
        return try coordinate(document, cancellation: cancellation) { coordinated in
            guard !cancellation.isCancelled, let storedVersion = NSFileVersion.version(itemAt: coordinated, forPersistentIdentifier: identifier), storedVersion.hasLocalContents else { throw ExtendedCleanupError.rejected("版本已不存在、未在本地或操作已取消。") }
            let id = UUID(), directory = self.root.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let backup = directory.appendingPathComponent("contents.archive")
            let copied = try self.copyVersion(storedVersion, to: backup, cancellation: cancellation)
            guard try self.digest(backup, cancellation: cancellation) == copied.0 else { throw ExtendedCleanupError.rejected("归档回读校验失败，未删除系统历史版本。") }
            var record = DocumentVersionArchiveRecord(id: id, documentPath: document.path, documentIdentity: identity, backupPath: backup.path, sha256: copied.0, bytes: copied.1, date: Date(), versionRemoved: false, restoredAsHistory: false)
            try self.save(record) // Receipt and complete backup precede system version removal.
            guard !cancellation.isCancelled, FileSafety.identity(document) == identity else { throw ExtendedCleanupError.rejected("当前文档已变化，未删除历史版本；备份已保留。") }
            try storedVersion.remove()
            record.versionRemoved = true; try self.save(record); return record
        }
    }
    public func restoreAsVersion(_ record: DocumentVersionArchiveRecord, confirmed: Bool, cancellation: MalwareCancellation = MalwareCancellation()) throws {
        guard confirmed else { throw ExtendedCleanupError.rejected("必须明确确认恢复的归档版本。") }
        guard let permit = WorkBudget.tryAcquire("恢复文档历史版本") else { throw ExtendedCleanupError.rejected("另一个重型操作正在运行。") }; defer { permit.release() }
        let deadlineTimer = operationDeadline(cancellation); defer { deadlineTimer.cancel() }
        try prepareRoot()
        guard let actual = try records().first(where: { $0.id == record.id }), !actual.restoredAsHistory, actual.backupPath == root.appendingPathComponent(record.id.uuidString).appendingPathComponent("contents.archive").path else { throw ExtendedCleanupError.rejected("找不到可恢复的匹配归档。") }
        let document = URL(fileURLWithPath: actual.documentPath), backup = URL(fileURLWithPath: actual.backupPath)
        guard let current = FileSafety.identity(document), current.device == actual.documentIdentity.device, current.inode == actual.documentIdentity.inode, current.size <= 200_000_000, !FileSafety.hasSymlinkComponent(document), try digest(backup, cancellation: cancellation) == actual.sha256 else { throw ExtendedCleanupError.rejected("当前文档或备份身份已变化。") }
        try coordinate(document, cancellation: cancellation) { coordinated in
            guard !cancellation.isCancelled else { throw ExtendedCleanupError.cancelled }
            let before = try self.digest(coordinated, cancellation: cancellation)
            _ = try NSFileVersion.addOfItem(at: coordinated, withContentsOf: backup, options: [])
            guard FileSafety.identity(coordinated) == current, try self.digest(coordinated, cancellation: cancellation) == before else { throw ExtendedCleanupError.rejected("系统创建历史版本后当前文档发生变化，请人工核对。") }
            var restored = actual; restored.restoredAsHistory = true; try self.save(restored)
        }
    }
    private func operationDeadline(_ cancellation: MalwareCancellation) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 120); timer.setEventHandler { cancellation.cancel() }; timer.resume(); return timer
    }
    private func coordinate<T>(_ document: URL, cancellation: MalwareCancellation, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200)); timer.setEventHandler { if cancellation.isCancelled { coordinator.cancel() } }; timer.resume(); defer { timer.cancel() }
        var coordinationError: NSError?, result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: document, options: [], error: &coordinationError) { url in result = Result { try body(url) } }
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw ExtendedCleanupError.rejected("系统未获得文档协调访问权限。")
    }
    private func digest(_ url: URL, cancellation: MalwareCancellation) throws -> String {
        let fd = try MalwareFiles.openRegular(url); defer { close(fd) }
        var hash = SHA256(), bytes = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while true {
            guard !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw ExtendedCleanupError.cancelled }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ExtendedCleanupError.rejected("读取归档校验内容失败。") }
            if count == 0 { break }
            bytes += count; guard bytes <= 200_000_000 else { throw ExtendedCleanupError.rejected("校验内容超过200MB上限。") }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    // Only called with a native NSFileVersion returned by the system after the
    // document identity and process-local capability token have been verified.
    // Version-store ancestors intentionally allow search but not directory reads;
    // O_SEARCH preserves per-component NOFOLLOW without asking to enumerate them.
    private func copyVersion(_ sourceVersion: NSFileVersion, to destination: URL, cancellation: MalwareCancellation) throws -> (String, Int64) {
        guard sourceVersion.hasLocalContents, sourceVersion.url.isFileURL else { throw ExtendedCleanupError.rejected("历史版本不在本地，不读取或下载。") }
        let source = sourceVersion.url.standardizedFileURL
        var parent = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ExtendedCleanupError.rejected("无法取得本地版本只读搜索句柄。") }
        defer { close(parent) }
        for component in source.deletingLastPathComponent().pathComponents.dropFirst() {
            let next = openat(parent, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ExtendedCleanupError.rejected("系统版本路径不可安全搜索（errno \(errno)）。") }
            close(parent); parent = next
        }
        let input = openat(parent, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw ExtendedCleanupError.rejected("无法只读打开系统本地版本（errno \(errno)）。") }
        defer { close(input) }
        var st = stat()
        guard fstat(input, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0, st.st_size <= 200_000_000, FileSafety.identity(source) == MalwareFiles.identity(st) else { throw ExtendedCleanupError.rejected("版本不是稳定本地普通文件，或超过200MB处理上限。") }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw ExtendedCleanupError.rejected("无法创建版本备份。") }; defer { close(output) }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var hash = SHA256(), bytes: Int64 = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            guard !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw ExtendedCleanupError.cancelled }
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw ExtendedCleanupError.rejected("读取历史内容失败。") }; if count == 0 { break }
            bytes += Int64(count); guard bytes <= 200_000_000 else { throw ExtendedCleanupError.rejected("版本读取超过体积上限。") }
            hash.update(data: Data(buffer.prefix(count)))
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }; guard written > 0 else { throw ExtendedCleanupError.rejected("写入版本归档失败。") }; offset += written
                }
            }
        }
        var after = stat()
        guard bytes == Int64(st.st_size), fstat(input, &after) == 0, MalwareFiles.identity(after) == MalwareFiles.identity(st), after.st_ctimespec.tv_sec == st.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == st.st_ctimespec.tv_nsec, FileSafety.identity(source) == MalwareFiles.identity(st), sourceVersion.url.standardizedFileURL.path == source.path, sourceVersion.hasLocalContents, fsync(output) == 0 else { throw ExtendedCleanupError.rejected("版本内容已变化或归档未完整落盘，未删除系统历史。") }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
