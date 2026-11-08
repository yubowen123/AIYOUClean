import Foundation
import Darwin

/// Metadata-only logical totals. Hard links count once per pathname, matching
/// the existing logical-size semantics; this is not a reclaimable-space estimate.
public struct MetadataTreeSummary: Sendable {
    public var logicalBytes: Int64
    public var visitedEntries: Int
    public var complete: Bool
    public var skippedEntries: Int
    public var unsafeToTrash: Bool
    public var warnings: [String]
    public init(logicalBytes: Int64 = 0, visitedEntries: Int = 0, complete: Bool = true, skippedEntries: Int = 0, unsafeToTrash: Bool = false, warnings: [String] = []) {
        self.logicalBytes = logicalBytes; self.visitedEntries = visitedEntries; self.complete = complete
        self.skippedEntries = skippedEntries; self.unsafeToTrash = unsafeToTrash; self.warnings = warnings
    }
}

public enum MetadataTreeWalker {
    /// The caller owns work leases, counters, resource budgets and cancellation.
    /// Only descendants call onVisit: the root has already been counted upstream.
    /// No contents, URL resource values, whole-directory arrays or inode/path sets.
    /// maxDepth bounds simultaneously open directory streams, not tree depth:
    /// deeper directories spill to a private disk queue and are reopened no-follow.
    public static func summarize(root: URL, excludedPaths: [String] = [], maxDepth: Int = 128, shouldStop: () -> Bool, onVisit: (String) -> Void) -> MetadataTreeSummary {
        withoutActuallyEscaping(shouldStop) { stop in
            withoutActuallyEscaping(onVisit) { visit in
                let work = MetadataTreeWork(root: root, excludedPaths: excludedPaths, maxDepth: maxDepth, shouldStop: stop, onVisit: visit)
                return work.run()
            }
        }
    }
}

private final class MetadataTreeWork {
    private let root: URL
    private let rootPath: String
    private let excludedPaths: [String]
    private let maximumDepth: Int
    private let shouldStop: () -> Bool
    private let onVisit: (String) -> Void
    private var result = MetadataTreeSummary()
    // At most 30 entries, never one key per visited file or per suppressed error.
    private var warningKeys = Set<String>()
    private var stopped = false
    private var deferredDirectories: MetadataDirectoryQueue?
    private let skippedDirectoryNames: Set<String> = [".git", ".Trash", ".DocumentRevisions-V100", ".Spotlight-V100", ".fseventsd"]
    init(root: URL, excludedPaths: [String], maxDepth: Int, shouldStop: @escaping () -> Bool, onVisit: @escaping (String) -> Void) {
        let normalizedRoot = root.standardizedFileURL
        self.root = normalizedRoot; rootPath = normalizedRoot.path
        self.excludedPaths = excludedPaths.filter { Self.contains(normalizedRoot.path, $0) || Self.contains($0, normalizedRoot.path) }
        maximumDepth = min(128, max(1, maxDepth)); self.shouldStop = shouldStop; self.onVisit = onVisit
        if maxDepth < 1 { fail("同时打开的目录层数必须至少为1。", key: "invalid-depth"); stopped = true }
        if excludedPaths.contains(where: { !$0.hasPrefix("/") || $0.utf8.contains(0) || $0.split(separator: "/").contains("..") }) {
            fail("传入了未规范化的忽略路径，未继续统计。", key: "invalid-rule"); stopped = true
        }
    }
    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
    private func excluded(_ path: String) -> Bool {
        !excludedPaths.isEmpty && excludedPaths.contains { Self.contains($0, path) }
    }
    private func warn(_ message: String, key: String) {
        guard result.warnings.count < 30, warningKeys.insert(key).inserted else { return }
        result.warnings.append(message)
    }
    private func fail(_ message: String, key: String) {
        result.complete = false; result.unsafeToTrash = true; warn(message, key: key)
    }
    private func skip(_ message: String, key: String) {
        result.skippedEntries += 1; result.unsafeToTrash = true; warn(message, key: key)
    }
    private func stopRequested() -> Bool {
        if stopped { return true }
        if shouldStop() {
            stopped = true; fail("统计已取消或触及上层预算；大小仅覆盖已检查部分。", key: "stopped"); return true
        }
        return false
    }
    private func addBytes(_ stat: stat) {
        let bytes = Int64(stat.st_size)
        guard bytes >= 0 else { fail("文件返回了无效逻辑大小。", key: "negative-size"); return }
        let sum = result.logicalBytes.addingReportingOverflow(bytes)
        if sum.overflow { result.logicalBytes = Int64.max; fail("逻辑总大小超出Int64范围，结果已饱和。", key: "size-overflow") }
        else { result.logicalBytes = sum.partialValue }
    }
    private func sameObject(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT) }
    private func sameDirectorySnapshot(_ a: stat, _ b: stat) -> Bool {
        sameObject(a, b) && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func dataless(_ metadata: stat) -> Bool { metadata.st_flags & UInt32(SF_DATALESS) != 0 }
    func run() -> MetadataTreeSummary {
        guard root.isFileURL, rootPath.hasPrefix("/"), !rootPath.utf8.contains(0) else { fail("统计根路径不是有效本地绝对路径。", key: "invalid-root"); return result }
        guard !stopRequested() else { return result }
        // A configured ignored descendant makes whole-directory removal unsafe,
        // even when that descendant does not currently exist on disk.
        if excludedPaths.contains(where: { Self.contains(rootPath, $0) }) { result.unsafeToTrash = true }
        if excluded(rootPath) { skip("根路径在忽略范围内，未读取。", key: "ignored-root"); return result }
        var parent = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { fail("无法安全打开统计根目录（errno \(errno)）。", key: "root-open"); return result }
        defer { if parent >= 0 { close(parent) } }
        let components = root.pathComponents.dropFirst()
        for component in components.dropLast() {
            if stopRequested() { return result }
            var metadata = stat()
            guard fstatat(parent, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { fail("无法读取根路径祖先（errno \(errno)）：\(rootPath)", key: "root-ancestor-stat"); return result }
            if metadata.st_mode & S_IFMT == S_IFLNK { skip("根路径含符号链接，未跟随：\(rootPath)", key: "root-link"); return result }
            if dataless(metadata) { skip("根路径祖先为云占位目录，未打开：\(rootPath)", key: "root-dataless"); return result }
            guard metadata.st_mode & S_IFMT == S_IFDIR else { fail("根路径祖先不是目录：\(rootPath)", key: "root-ancestor-type"); return result }
            let next = openat(parent, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { fail("无法安全搜索根路径祖先（errno \(errno)）：\(rootPath)", key: "root-ancestor-open"); return result }
            var opened = stat()
            guard fstat(next, &opened) == 0, sameObject(opened, metadata) else { close(next); fail("根路径祖先在打开期间发生变化。", key: "root-ancestor-change"); return result }
            close(parent); parent = next
        }
        let name = components.last ?? "."
        var rootMetadata = stat()
        guard fstatat(parent, name, &rootMetadata, AT_SYMLINK_NOFOLLOW) == 0 else { fail("统计根路径不存在或不可访问（errno \(errno)）：\(rootPath)", key: "root-stat"); return result }
        let type = rootMetadata.st_mode & S_IFMT
        if type == S_IFLNK { skip("根路径是符号链接，未跟随：\(rootPath)", key: "root-link"); return result }
        if dataless(rootMetadata) { skip("根路径为未下载云内容，未打开：\(rootPath)", key: "root-dataless"); return result }
        if type == S_IFREG { addBytes(rootMetadata); return result }
        guard type == S_IFDIR else { skip("根路径为特殊文件，未读取：\(rootPath)", key: "root-special"); return result }
        if skippedDirectoryNames.contains(name) { skip("已按策略跳过目录：\(rootPath)", key: "policy-directory"); return result }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { fail("无法枚举统计根目录（errno \(errno)）：\(rootPath)", key: "root-directory-open"); return result }
        var openedRoot = stat()
        guard fstat(fd, &openedRoot) == 0, sameObject(openedRoot, rootMetadata) else { close(fd); fail("根目录在打开期间已替换。", key: "root-change"); return result }
        // The search-parent descriptor is no longer needed during recursion.
        close(parent); parent = -1
        walk(directoryFD: fd, path: rootPath, depth: 1, device: openedRoot.st_dev, initial: openedRoot)
        drainDeferredDirectories(rootMetadata: openedRoot)
        if let queue = deferredDirectories {
            do { try queue.dispose() }
            catch { fail("无法清理本次目录队列：\(error.localizedDescription)", key: "queue-cleanup") }
            deferredDirectories = nil
        }
        return result
    }
    private func deferDirectory(path: String, metadata: stat) {
        guard !stopRequested() else { return }
        do {
            let queue: MetadataDirectoryQueue
            if let existing = deferredDirectories { queue = existing }
            else { queue = try MetadataDirectoryQueue(); deferredDirectories = queue }
            try queue.append(MetadataQueuedDirectory(path: path, metadata: metadata))
        } catch {
            stopped = true
            fail("深目录队列写入失败，统计未完成：\(error.localizedDescription)", key: "queue-write")
        }
    }
    private func drainDeferredDirectories(rootMetadata: stat) {
        guard let queue = deferredDirectories else { return }
        while !stopRequested() {
            var finished = false
            autoreleasepool {
                do {
                    guard let pending = try queue.pop() else { finished = true; return }
                    // This directory was counted when discovered. Reopening it
                    // must neither count it again nor invoke onVisit again.
                    guard let opened = reopen(pending, rootMetadata: rootMetadata) else { return }
                    walk(directoryFD: opened.fd, path: pending.path, depth: 1, device: rootMetadata.st_dev, initial: opened.metadata)
                    if !stopRequested(), let check = reopen(pending, rootMetadata: rootMetadata) { close(check.fd) }
                } catch {
                    stopped = true
                    fail("深目录队列读取失败，统计未完成：\(error.localizedDescription)", key: "queue-read")
                }
            }
            if finished { break }
        }
    }
    /// Opens only directory metadata, one ancestor FD at a time. A queued path
    /// cannot turn into a symlink, a mount traversal, or a replacement root.
    private func reopen(_ pending: MetadataQueuedDirectory, rootMetadata: stat) -> (fd: Int32, metadata: stat)? {
        guard Self.contains(rootPath, pending.path), pending.path != rootPath else {
            fail("深目录队列路径超出统计范围。", key: "queue-path"); return nil
        }
        var parent = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { fail("无法安全重开深目录祖先（errno \(errno)）。", key: "queue-root-open"); return nil }
        defer { if parent >= 0 { close(parent) } }
        var traversed = ""
        if rootPath == "/" {
            var opened = stat()
            guard fstat(parent, &opened) == 0, sameDirectorySnapshot(opened, rootMetadata), !dataless(opened) else {
                fail("统计根目录在深目录重开前发生变化。", key: "queue-root-changed"); return nil
            }
        }
        let components = pending.path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            guard !stopRequested() else { return nil }
            let name = String(component)
            traversed += "/" + name
            let inSelectedTree = Self.contains(rootPath, traversed)
            var before = stat()
            guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                fail("深目录祖先不存在或不可访问（errno \(errno)）：\(pending.path)", key: "queue-ancestor-stat"); return nil
            }
            guard before.st_mode & S_IFMT == S_IFDIR, !dataless(before) else {
                fail("深目录祖先已变为链接、占位或非目录，未跟随：\(pending.path)", key: "queue-ancestor-type"); return nil
            }
            if inSelectedTree && (before.st_dev != rootMetadata.st_dev || excluded(traversed) || skippedDirectoryNames.contains(name)) {
                fail("深目录祖先已超出同卷或允许的统计范围：\(pending.path)", key: "queue-ancestor-scope"); return nil
            }
            if traversed == rootPath && !sameDirectorySnapshot(before, rootMetadata) {
                fail("统计根目录在深目录重开前已被替换。", key: "queue-root-changed"); return nil
            }
            let last = index == components.count - 1
            let next = openat(parent, name, (last ? O_RDONLY : O_SEARCH) | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { fail("无法安全重开深目录（errno \(errno)）：\(pending.path)", key: "queue-directory-open"); return nil }
            var opened = stat()
            guard fstat(next, &opened) == 0, sameObject(opened, before), !dataless(opened) else {
                close(next); fail("深目录在重开期间发生变化：\(pending.path)", key: "queue-directory-race"); return nil
            }
            close(parent); parent = next
            if last {
                guard pending.matches(opened) else {
                    fail("排队的深目录已被移动、替换或修改：\(pending.path)", key: "queue-directory-changed"); return nil
                }
                let answer = parent; parent = -1
                return (answer, opened)
            }
        }
        fail("深目录队列没有有效目录分量。", key: "queue-path"); return nil
    }
    /// Consumes directoryFD. fdopendir owns it; one live descriptor per depth.
    private func walk(directoryFD: Int32, path: String, depth: Int, device: dev_t, initial: stat) {
        guard !stopRequested() else { close(directoryFD); return }
        guard let directory = fdopendir(directoryFD) else { let error = errno; close(directoryFD); fail("无法创建目录流（errno \(error)）：\(path)", key: "directory-stream"); return }
        defer { closedir(directory) }
        let parent = dirfd(directory)
        while !stopRequested() {
            var exhausted = false
            autoreleasepool {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { fail("目录读取失败（errno \(errno)）：\(path)", key: "directory-read") }
                    exhausted = true; return
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let name else {
                    result.visitedEntries += 1; onVisit(path + "/[无法解析名称]")
                    result.skippedEntries += 1; fail("目录含无法表达为UTF-8的名称，已跳过。", key: "invalid-name"); return
                }
                if name == "." || name == ".." { return }
                let childPath = path == "/" ? "/" + name : path + "/" + name
                result.visitedEntries += 1; onVisit(childPath)
                if excluded(childPath) { skip("已跳过忽略路径及其子项。", key: "ignored-entry"); return }
                var metadata = stat()
                guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { result.skippedEntries += 1; fail("无法读取目录项属性（errno \(errno)）：\(childPath)", key: "entry-stat"); return }
                let type = metadata.st_mode & S_IFMT
                if type == S_IFLNK { skip("已跳过符号链接，不向范围外遍历。", key: "symlink"); return }
                if dataless(metadata) { skip("已跳过未下载的云占位内容。", key: "dataless"); return }
                if type == S_IFREG { addBytes(metadata); return }
                guard type == S_IFDIR else { skip("已跳过特殊文件。", key: "special"); return }
                if skippedDirectoryNames.contains(name) { skip("已跳过策略目录（.git、废纸篓或系统索引/版本目录）。", key: "policy-directory"); return }
                if metadata.st_dev != device { skip("已跳过跨设备目录。", key: "cross-device"); return }
                if depth >= maximumDepth { deferDirectory(path: childPath, metadata: metadata); return }
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { result.skippedEntries += 1; fail("无法打开子目录（errno \(errno)）：\(childPath)", key: "child-open"); return }
                var opened = stat()
                guard fstat(child, &opened) == 0, sameObject(opened, metadata) else { close(child); result.skippedEntries += 1; fail("子目录在打开期间发生变化：\(childPath)", key: "child-change"); return }
                if dataless(opened) { close(child); skip("打开前云目录状态已变化，未遍历。", key: "dataless"); return }
                walk(directoryFD: child, path: childPath, depth: depth + 1, device: device, initial: opened)
                var after = stat()
                if fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) != 0 || !sameObject(after, opened) { fail("已统计目录被移动或替换：\(childPath)", key: "child-detached") }
            }
            if exhausted { break }
        }
        var final = stat()
        if fstat(parent, &final) != 0 || !sameDirectorySnapshot(final, initial) {
            fail("目录在体积统计期间变化，大小仅为部分观察：\(path)", key: "directory-mutated")
        }
    }
}

private struct MetadataQueuedDirectory {
    let path: String
    let device: Int64, inode: Int64, modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(path: String, metadata: stat) {
        self.path = path; device = Int64(metadata.st_dev); inode = Int64(bitPattern: UInt64(metadata.st_ino))
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec); modifiedNanos = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec); changedNanos = Int64(metadata.st_ctimespec.tv_nsec)
    }
    init(path: String, device: Int64, inode: Int64, modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64) {
        self.path = path; self.device = device; self.inode = inode
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos; self.changedSeconds = changedSeconds; self.changedNanos = changedNanos
    }
    func matches(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR && device == Int64(metadata.st_dev) && inode == Int64(bitPattern: UInt64(metadata.st_ino)) &&
        modifiedSeconds == Int64(metadata.st_mtimespec.tv_sec) && modifiedNanos == Int64(metadata.st_mtimespec.tv_nsec) &&
        changedSeconds == Int64(metadata.st_ctimespec.tv_sec) && changedNanos == Int64(metadata.st_ctimespec.tv_nsec)
    }
}

/// A private UUID session, not an array of pending paths. Shared SQLite plumbing
/// enforces 0700/0600 ownership, 2 MiB cache, no mmap and disk temporary storage.
private final class MetadataDirectoryQueue {
    private let database: ScanSQLiteConnection
    private var disposed = false
    init() throws {
        let location = try ScanOwnedLocation.create(.candidates)
        do {
            let connection = try ScanSQLiteConnection(location: location, readOnly: false, creating: true)
            try connection.execute("CREATE TABLE metadata_pending(sequence INTEGER PRIMARY KEY,path TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,modified_seconds INTEGER NOT NULL,modified_nanos INTEGER NOT NULL,changed_seconds INTEGER NOT NULL,changed_nanos INTEGER NOT NULL); INSERT INTO scan_meta(key,value) VALUES('index_type','metadata-depth-queue-v1');")
            database = connection
        } catch { try? location.removeArtifacts(); throw error }
    }
    deinit { if !disposed { try? dispose() } }
    func append(_ pending: MetadataQueuedDirectory) throws {
        try database.beginWrite()
        let statement = try database.prepare("INSERT INTO metadata_pending(path,device,inode,modified_seconds,modified_nanos,changed_seconds,changed_nanos) VALUES(?,?,?,?,?,?,?)")
        try statement.text(pending.path, at: 1); try statement.integer(pending.device, at: 2); try statement.integer(pending.inode, at: 3)
        try statement.integer(pending.modifiedSeconds, at: 4); try statement.integer(pending.modifiedNanos, at: 5)
        try statement.integer(pending.changedSeconds, at: 6); try statement.integer(pending.changedNanos, at: 7)
        _ = try statement.step(); try database.didWrite()
    }
    func pop() throws -> MetadataQueuedDirectory? {
        let next: (Int64, MetadataQueuedDirectory)? = try autoreleasepool {
            let statement = try database.prepare("SELECT sequence,path,device,inode,modified_seconds,modified_nanos,changed_seconds,changed_nanos FROM metadata_pending ORDER BY sequence LIMIT 1")
            guard try statement.step() else { return nil }
            return (statement.integer(0), MetadataQueuedDirectory(path: try statement.string(1), device: statement.integer(2), inode: statement.integer(3), modifiedSeconds: statement.integer(4), modifiedNanos: statement.integer(5), changedSeconds: statement.integer(6), changedNanos: statement.integer(7)))
        }
        guard let next else { return nil }
        try database.beginWrite()
        let removal = try database.prepare("DELETE FROM metadata_pending WHERE sequence=?")
        try removal.integer(next.0, at: 1); _ = try removal.step(); try database.didWrite()
        return next.1
    }
    func dispose() throws {
        guard !disposed else { return }
        try database.close(); try database.location.removeArtifacts(); disposed = true
    }
}
