import Foundation
import Darwin
import CryptoKit
import CSQLite

public struct FullDiskCoverage: Sendable {
    public var roots: [String]
    public var notes: [String]
    public var visitedEntries: Int
    public var regularFiles: Int
    public var logicalBytes: Int64
    public var inaccessibleEntries: Int
    public var skippedCloudEntries: Int
    public var skippedLinkEntries: Int
    public var excludedEntries: Int
    public var incomplete: Bool
    public var cancelled: Bool
    public var issueStore: ScanResultReference?
    public var issueCount: Int
    public init(roots: [String] = [], notes: [String] = [], visitedEntries: Int = 0, regularFiles: Int = 0,
                logicalBytes: Int64 = 0, inaccessibleEntries: Int = 0, skippedCloudEntries: Int = 0,
                skippedLinkEntries: Int = 0, excludedEntries: Int = 0, incomplete: Bool = false,
                cancelled: Bool = false, issueStore: ScanResultReference? = nil, issueCount: Int = 0) {
        self.roots = roots; self.notes = notes; self.visitedEntries = visitedEntries; self.regularFiles = regularFiles
        self.logicalBytes = logicalBytes; self.inaccessibleEntries = inaccessibleEntries
        self.skippedCloudEntries = skippedCloudEntries; self.skippedLinkEntries = skippedLinkEntries
        self.excludedEntries = excludedEntries; self.incomplete = incomplete; self.cancelled = cancelled; self.issueStore = issueStore; self.issueCount = issueCount
    }
}
public struct FullDiskFileReport: Sendable {
    public var largeFiles: ScanReport
    public var duplicates: ScanReport
    public var coverage: FullDiskCoverage
    public init(largeFiles: ScanReport, duplicates: ScanReport, coverage: FullDiskCoverage) {
        self.largeFiles = largeFiles; self.duplicates = duplicates; self.coverage = coverage
    }
}

/// Pure policy seam: only the logical startup root can admit its confirmed local
/// Data partner. An arbitrary selected root never borrows the home/Data device.
enum FullDiskVolumePolicy {
    static func allowedDevices(rootPath: String, rootDevice: UInt64, startupDataDevice: UInt64?, startupDataIsLocal: Bool) -> [UInt64] {
        if rootPath == "/", startupDataIsLocal, let startupDataDevice, startupDataDevice != rootDevice {
            return [rootDevice, startupDataDevice]
        }
        return [rootDevice]
    }
}
enum FullDiskPathPolicy {
    static func isManagedIndex(path: String, temporaryBase: String) -> Bool {
        guard path != temporaryBase, FileSafety.contains(temporaryBase, path) else { return false }
        let relative = path.dropFirst(temporaryBase.count).split(separator: "/")
        guard let first = relative.first else { return false }
        let name = String(first)
        for prefix in ["AIYOUClean-results-", "AIYOUClean-candidates-", "AIYOUClean-CLI-"] where name.hasPrefix(prefix) {
            if UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }
}

private struct FullDiskDirectory {
    let path: String
    let root: String
    let primaryDevice: UInt64
    let dataDevice: UInt64?
    let primaryWritable: Bool
    let dataWritable: Bool
    let package: Bool
    let expectedDevice: UInt64
    let expectedInode: UInt64
    func admits(_ device: UInt64) -> Bool { device == primaryDevice || device == dataDevice }
    func writable(_ device: UInt64) -> Bool { device == primaryDevice ? primaryWritable : device == dataDevice && dataWritable }
}
private struct FullDiskFilePolicy {
    let writable: Bool
    let package: Bool
    let owner: UInt64
}

/// Queue, visited identities and per-file safety context grow on disk. SQLite's
/// 2MiB cache and file-backed temporary tables bound process working memory.
private final class FullDiskTraversalIndex {
    let database: ScanSQLiteConnection
    private var disposed = false
    static func create() throws -> FullDiskTraversalIndex {
        let location = try ScanOwnedLocation.create(.candidates)
        do { return try FullDiskTraversalIndex(database: ScanSQLiteConnection(location: location, readOnly: false, creating: true)) }
        catch { try? location.removeArtifacts(); throw error }
    }
    private init(database: ScanSQLiteConnection) throws {
        self.database = database
        try database.execute("""
        CREATE TABLE full_seen(device INTEGER NOT NULL,inode INTEGER NOT NULL,kind INTEGER NOT NULL,PRIMARY KEY(device,inode,kind));
        CREATE TABLE full_queue(sequence INTEGER PRIMARY KEY,path TEXT NOT NULL,root TEXT NOT NULL,primary_device INTEGER NOT NULL,data_device INTEGER,primary_writable INTEGER NOT NULL,data_writable INTEGER NOT NULL,package INTEGER NOT NULL,expected_device INTEGER NOT NULL,expected_inode INTEGER NOT NULL);
        CREATE TABLE full_policy(path TEXT PRIMARY KEY,writable INTEGER NOT NULL,package INTEGER NOT NULL,owner INTEGER NOT NULL);
        CREATE TABLE full_inaccessible(path TEXT PRIMARY KEY);
        """)
    }
    deinit { try? dispose() }
    func markSeen(_ metadata: stat) throws -> Bool {
        try database.beginWrite()
        let row = try database.prepare("INSERT OR IGNORE INTO full_seen VALUES(?,?,?)")
        try row.integer(Int64(metadata.st_dev), at: 1); try row.integer(Int64(bitPattern: UInt64(metadata.st_ino)), at: 2)
        try row.integer(Int64(metadata.st_mode & S_IFMT), at: 3); _ = try row.step()
        let inserted = sqlite3_changes(database.pointer) == 1; try database.didWrite(); return inserted
    }
    func enqueue(_ directory: FullDiskDirectory) throws {
        try database.beginWrite()
        let row = try database.prepare("INSERT INTO full_queue(path,root,primary_device,data_device,primary_writable,data_writable,package,expected_device,expected_inode) VALUES(?,?,?,?,?,?,?,?,?)")
        try row.text(directory.path, at: 1); try row.text(directory.root, at: 2)
        try row.integer(Int64(bitPattern: directory.primaryDevice), at: 3)
        if let device = directory.dataDevice { try row.integer(Int64(bitPattern: device), at: 4) }
        try row.integer(directory.primaryWritable ? 1 : 0, at: 5); try row.integer(directory.dataWritable ? 1 : 0, at: 6)
        try row.integer(directory.package ? 1 : 0, at: 7); try row.integer(Int64(bitPattern: directory.expectedDevice), at: 8)
        try row.integer(Int64(bitPattern: directory.expectedInode), at: 9); _ = try row.step(); try database.didWrite()
    }
    func pop() throws -> FullDiskDirectory? {
        let row = try database.prepare("SELECT sequence,path,root,primary_device,data_device,primary_writable,data_writable,package,expected_device,expected_inode FROM full_queue ORDER BY sequence LIMIT 1")
        guard try row.step() else { return nil }
        let sequence = row.integer(0)
        let directory = FullDiskDirectory(path: try row.string(1), root: try row.string(2), primaryDevice: UInt64(bitPattern: row.integer(3)),
                                          dataDevice: sqlite3_column_type(row.pointer, 4) == SQLITE_NULL ? nil : UInt64(bitPattern: row.integer(4)),
                                          primaryWritable: row.integer(5) != 0, dataWritable: row.integer(6) != 0, package: row.integer(7) != 0,
                                          expectedDevice: UInt64(bitPattern: row.integer(8)), expectedInode: UInt64(bitPattern: row.integer(9)))
        try database.beginWrite(); let remove = try database.prepare("DELETE FROM full_queue WHERE sequence=?")
        try remove.integer(sequence, at: 1); _ = try remove.step(); try database.didWrite(); return directory
    }
    func recordPolicy(path: String, metadata: stat, writable: Bool, package: Bool) throws {
        try database.beginWrite(); let row = try database.prepare("INSERT INTO full_policy VALUES(?,?,?,?)")
        try row.text(path, at: 1); try row.integer(writable ? 1 : 0, at: 2); try row.integer(package ? 1 : 0, at: 3)
        try row.integer(Int64(metadata.st_uid), at: 4); _ = try row.step(); try database.didWrite()
    }
    func policy(_ path: String) throws -> FullDiskFilePolicy? {
        let row = try database.prepare("SELECT writable,package,owner FROM full_policy WHERE path=?")
        try row.text(path, at: 1); guard try row.step() else { return nil }
        return .init(writable: row.integer(0) != 0, package: row.integer(1) != 0, owner: UInt64(row.integer(2)))
    }
    func firstInaccessible(_ path: String) throws -> Bool {
        try database.beginWrite(); let row = try database.prepare("INSERT OR IGNORE INTO full_inaccessible VALUES(?)")
        try row.text(path, at: 1); _ = try row.step(); let inserted = sqlite3_changes(database.pointer) == 1
        try database.didWrite(); return inserted
    }
    func dispose() throws {
        if disposed { return }; try database.close(); try database.location.removeArtifacts(); disposed = true
    }
}

private struct FullDiskIssuePayload: Encodable {
    let id = UUID().uuidString
    let path: String
    let name: String
    let category: String
    let detail: String
    let bytes: Int64 = 0
    let canTrash = false
    var item: ScanItem { get throws { try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(self)) } }
}
private enum FullDiskReadError: Error {
    case io(String, Int32), changed(String), configuration(String), cancelled
}

public final class FullDiskFileScanner {
    public init() {}
    public func scan(plan: FullDiskScanPlan, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     largeFileBytes: Int64 = 100_000_000, cancellation: MalwareCancellation = .init(), excludedPaths: [String] = [],
                     progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }) -> FullDiskFileReport {
        guard let permit = WorkBudget.tryAcquire("全盘文件检查") else {
            let note = "另一项重操作正在运行，未进行全盘文件检查。"
            return .init(largeFiles: .init(kind: .largeFiles, warnings: [note], truncated: true, stopReason: .busy),
                         duplicates: .init(kind: .duplicates, warnings: [note], truncated: true, stopReason: .busy),
                         coverage: .init(roots: plan.roots.map(\.path), notes: plan.notes + [note], incomplete: true))
        }
        defer { permit.release() }
        let work = FullDiskFileWork(plan: plan, home: home, threshold: max(1, largeFileBytes), cancellation: cancellation, excludedPaths: excludedPaths, progress: progress)
        return work.run()
    }
}

private final class FullDiskFileWork {
    let plan: FullDiskScanPlan
    let home: URL
    let threshold: Int64
    let explicitIgnores: [String]
    let cancellation: MalwareCancellation
    let progress: @Sendable (Int, String) -> Void
    let started = Date()
    let temporaryBase = ScanOwnedLocation.base.path
    var coverage: FullDiskCoverage
    var large = ScanReport(kind: .largeFiles)
    var duplicates = ScanReport(kind: .duplicates)
    var largeStore: ScanResultStore?
    var duplicateStore: ScanResultStore?
    var issues: ScanResultStore?
    var traversal: FullDiskTraversalIndex?
    var candidates: ScanCandidateIndex?
    var ignores: [(String, String)] = []
    var ignorePaths: [String] = []
    var policyExclusions: [String] = []
    var roots: [URL] = []
    var lastProgress = Date.distantPast
    var peakRSS: UInt64 = 0
    var lastRSS = Date.distantPast
    var fatal: ScanStopReason?
    var hashingBegan = false
    init(plan: FullDiskScanPlan, home: URL, threshold: Int64, cancellation: MalwareCancellation, excludedPaths: [String], progress: @escaping @Sendable (Int, String) -> Void) {
        self.plan = plan; self.home = home.standardizedFileURL; self.threshold = threshold; self.cancellation = cancellation; self.explicitIgnores = excludedPaths; self.progress = progress
        coverage = .init(notes: plan.notes)
    }
    func checkCancellation() throws { if cancellation.isCancelled { throw FullDiskReadError.cancelled } }
    func run() -> FullDiskFileReport {
        do {
            issues = try ScanResultStore.createTemporary(); coverage.issueStore = issues?.reference
            let rules: [String]
            do { rules = try IgnoreRuleStore.normalize(Array(Set(try IgnoreRuleStore(home: home).load() + explicitIgnores))) }
            catch {
                fatal = .configurationError; coverage.incomplete = true
                coverage.notes.append("忽略清单无法读取，已停止且未开始遍历：" + error.localizedDescription)
                try issue(home.appendingPathComponent("Library/Application Support/AIYOUClean/ignore-rules.json").path, "忽略配置错误", error.localizedDescription)
                return finish()
            }
            ignorePaths = rules
            ignores = rules.map { ($0, $0 == "/" ? "/" : $0 + "/") }
            // Policy is not a user ignore list; its strict-root-descendant rule
            // preserves explicitly listed data roots below /Volumes or a mount.
            for raw in plan.excludedPaths {
                guard raw.hasPrefix("/"), !raw.utf8.contains(0) else { throw FullDiskReadError.configuration("全盘排除策略不是有效绝对路径。") }
                let path = ScanLexicalPath.normalize(raw)
                if !policyExclusions.contains(path) { policyExclusions.append(path) }
            }
            for input in plan.roots {
                guard input.isFileURL, input.host == nil || input.host == "" || input.host == "localhost",
                      input.path.hasPrefix("/"), !input.path.utf8.contains(0) else { throw FullDiskReadError.configuration("扫描根必须是有效本地绝对路径。") }
                let root = URL(fileURLWithPath: ScanLexicalPath.normalize(input.path), isDirectory: true)
                if !roots.contains(where: { $0.path == root.path }) { roots.append(root) }
            }
            roots.sort {
                func priority(_ path: String) -> Int { path == "/" ? 2 : FileSafety.contains(home.path, path) ? 0 : 1 }
                let a = priority($0.path), b = priority($1.path)
                return a == b ? $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count : a < b
            }
            coverage.roots = roots.map(\.path)
            guard !roots.isEmpty else { throw FullDiskReadError.configuration("未提供扫描根；没有自动扩展到真实磁盘或用户目录。") }
            coverage.notes.append("目录项逐个读取；常规文件及逻辑量按设备号/inode去重。被排除目录按入口计数，不推测其中未读取的数量。")
            coverage.notes.append("系统、应用包、他人文件、用户Library及隐藏配置只供查看；可处理项仍须本人拥有、所在卷可写并通过保护路径检查。")
            largeStore = try ScanResultStore.createTemporary(); duplicateStore = try ScanResultStore.createTemporary()
            large.resultStore = largeStore?.reference; duplicates.resultStore = duplicateStore?.reference
            traversal = try FullDiskTraversalIndex.create(); candidates = try ScanCandidateIndex.createTemporary()
            for root in roots {
                try checkCancellation()
                try autoreleasepool { try enterRoot(root) }
                while let directory = try autoreleasepool(invoking: { try traversal?.pop() }) {
                    try checkCancellation(); try autoreleasepool { try readDirectory(directory) }
                }
            }
            try findDuplicates()
        } catch FullDiskReadError.configuration(let reason) {
            coverage.incomplete = true; fatal = .configurationError; coverage.notes.append(reason)
            try? issue(home.path, "范围配置错误", reason)
        } catch FullDiskReadError.cancelled {
            coverage.cancelled = true; coverage.incomplete = true; fatal = .cancelled
        } catch ScanStoreError.cancelled {
            coverage.cancelled = cancellation.isCancelled; coverage.incomplete = true; fatal = cancellation.isCancelled ? .cancelled : .storageError
        } catch {
            coverage.incomplete = true; fatal = .storageError
            coverage.notes.append("落盘索引或检查无法继续；已保留已提交部分：" + error.localizedDescription)
            try? issue(roots.first?.path ?? home.path, "检查无法继续", error.localizedDescription)
        }
        return finish()
    }
    func ignored(_ path: String) -> Bool {
        if ignores.contains(where: { path == $0.0 || path.hasPrefix($0.1) }) { return true }
        // Existing saved rules use Foundation's /var and /tmp alias spelling;
        // match those as well without changing the literal source path for I/O.
        return path.hasPrefix("/private/") && IgnoreRuleStore.isExcluded(path, by: ignorePaths)
    }
    func policyExcluded(_ path: String, root: String) -> Bool {
        policyExclusions.contains { $0 != root && FileSafety.contains(root, $0) && FileSafety.contains($0, path) }
    }
    func isOwnIndex(_ path: String) -> Bool {
        FullDiskPathPolicy.isManagedIndex(path: path, temporaryBase: temporaryBase)
    }
    func issue(_ path: String, _ category: String, _ detail: String) throws {
        let payload = FullDiskIssuePayload(path: path, name: URL(fileURLWithPath: path).lastPathComponent, category: category, detail: detail)
        try issues?.append(payload.item)
    }
    func failure(_ path: String, _ stage: String, _ code: Int32, detail: String? = nil) throws {
        if try traversal?.firstInaccessible(path) ?? true { coverage.inaccessibleEntries += 1 }
        coverage.incomplete = true
        let reason = code == EPERM || code == EACCES ? "macOS拒绝访问" : "文件系统读取失败"
        try issue(path, reason, stage + "（errno \(code)）" + (detail.map { "：" + $0 } ?? ""))
    }
    func updateProgress(_ path: String, force: Bool = false) {
        if force || Date().timeIntervalSince(lastProgress) >= 0.2 { lastProgress = Date(); progress(coverage.visitedEntries, path) }
        if Date().timeIntervalSince(lastRSS) >= 0.2 { lastRSS = Date(); peakRSS = max(peakRSS, ProcessResources.residentBytes() ?? 0) }
    }
    func volumeFlags(_ path: String) -> (local: Bool, writable: Bool) {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return (false, false) }
        let local = fs.f_flags & UInt32(MNT_LOCAL) != 0
        return (local, local && fs.f_flags & UInt32(MNT_RDONLY) == 0)
    }
    func enterRoot(_ root: URL) throws {
        if ignored(root.path) || isOwnIndex(root.path) { coverage.excludedEntries += 1; try issue(root.path, "范围排除", "用户忽略规则或AIYOUClean自身索引目录，未读取。"); return }
        var info = stat()
        guard lstat(root.path, &info) == 0 else { try failure(root.path, "检查扫描根", errno); return }
        if info.st_mode & S_IFMT == S_IFLNK { coverage.skippedLinkEntries += 1; coverage.incomplete = true; try issue(root.path, "链接未跟随", "扫描根含符号链接，未进入其目标。"); return }
        if info.st_flags & UInt32(SF_DATALESS) != 0 { coverage.skippedCloudEntries += 1; coverage.incomplete = true; try issue(root.path, "云占位未下载", "未读取或请求下载云端内容。"); return }
        guard info.st_mode & S_IFMT == S_IFDIR else { try failure(root.path, "扫描根不是目录", ENOTDIR); return }
        // Validate the complete root chain before marking its inode visited;
        // an alias or unreadable ancestor must not suppress a later valid root.
        do {
            let verified = try ScanOwnedLocation.openDirectory(root, searchAncestors: true)
            defer { close(verified) }
            var opened = stat()
            guard fstat(verified, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                try failure(root.path, "根目录打开期间身份变化", ESTALE); return
            }
        } catch { try failure(root.path, "安全打开扫描根", errno == 0 ? EACCES : errno, detail: error.localizedDescription); return }
        guard try traversal?.markSeen(info) == true else { return }
        coverage.visitedEntries += 1
        let device = UInt64(info.st_dev), flags = volumeFlags(root.path)
        var dataDevice: UInt64?, dataLocal = false, dataWritable = false
        if root.path == "/" {
            var data = stat()
            if lstat("/System/Volumes/Data", &data) == 0, data.st_mode & S_IFMT == S_IFDIR {
                let flags = volumeFlags("/System/Volumes/Data")
                dataDevice = UInt64(data.st_dev); dataLocal = flags.local; dataWritable = flags.writable
            }
        }
        let devices = FullDiskVolumePolicy.allowedDevices(rootPath: root.path, rootDevice: device, startupDataDevice: dataDevice, startupDataIsLocal: dataLocal)
        let directory = FullDiskDirectory(path: root.path, root: root.path, primaryDevice: device, dataDevice: devices.count == 2 ? devices[1] : nil,
                                          primaryWritable: flags.writable, dataWritable: dataWritable, package: inPackage(root.path),
                                          expectedDevice: device, expectedInode: UInt64(info.st_ino))
        try traversal?.enqueue(directory)
    }
    func readDirectory(_ directory: FullDiskDirectory) throws {
        let url = URL(fileURLWithPath: directory.path)
        let fd: Int32
        do { fd = try ScanOwnedLocation.openDirectory(url, searchAncestors: true) }
        catch { try failure(directory.path, "打开目录", errno == 0 ? EACCES : errno, detail: error.localizedDescription); return }
        defer { close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, UInt64(current.st_dev) == directory.expectedDevice, UInt64(current.st_ino) == directory.expectedInode,
              current.st_flags & UInt32(SF_DATALESS) == 0 else { try failure(directory.path, "目录身份变化或成为云占位", ESTALE); return }
        guard let stream = fdopendir(dup(fd)) else { try failure(directory.path, "读取目录项", errno); return }
        defer { closedir(stream) }
        // On some APFS configurations the OS/Data filesystems expose identical
        // st_dev values even though statfs reports different read-only flags.
        // Query this directory's mount once, rather than inferring writability
        // of a logical Data firmlink from the sealed startup root's flag.
        let mountedWritable = volumeFlags(directory.path).writable
        while true {
            try checkCancellation()
            let more = try autoreleasepool { () throws -> Bool in
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { try failure(directory.path, "枚举目录", errno) }; return false }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { return true }
                let path = directory.path == "/" ? "/" + name : directory.path + "/" + name
                coverage.visitedEntries += 1; updateProgress(path)
                if ignored(path) || policyExcluded(path, root: directory.root) || isOwnIndex(path) {
                    coverage.excludedEntries += 1; try issue(path, "范围排除", "忽略规则、当前根的挂载去重策略或本工具临时索引；未递归此入口。"); return true
                }
                var metadata = stat()
                guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { try failure(path, "读取文件属性", errno); return true }
                let kind = metadata.st_mode & S_IFMT, device = UInt64(metadata.st_dev)
                if kind == S_IFLNK { coverage.skippedLinkEntries += 1; try issue(path, "链接未跟随", "只记录链接入口，不跟随目标。"); return true }
                if metadata.st_flags & UInt32(SF_DATALESS) != 0 { coverage.skippedCloudEntries += 1; coverage.incomplete = true; try issue(path, "云占位未下载", "没有读取占位内容或触发下载。"); return true }
                guard directory.admits(device) else {
                    coverage.excludedEntries += 1
                    if !roots.contains(where: { $0.path == path }) { coverage.incomplete = true }
                    try issue(path, "其他卷未递归", "此设备不在当前根允许卷组内；独立列出的卷由其自身根检查。"); return true
                }
                guard kind == S_IFREG || kind == S_IFDIR else { coverage.excludedEntries += 1; try issue(path, "特殊文件未读取", "没有打开套接字、设备、FIFO或其他特殊文件。"); return true }
                guard try traversal?.markSeen(metadata) == true else { return true }
                let package = directory.package || packageComponent(name)
                if kind == S_IFDIR {
                    try traversal?.enqueue(.init(path: path, root: directory.root, primaryDevice: directory.primaryDevice, dataDevice: directory.dataDevice,
                                                  primaryWritable: directory.primaryWritable, dataWritable: directory.dataWritable, package: package,
                                                  expectedDevice: device, expectedInode: UInt64(metadata.st_ino)))
                } else { try recordFile(path, metadata, directory: directory, package: package, writable: mountedWritable) }
                return true
            }
            if !more { break }
        }
    }
    func recordFile(_ path: String, _ metadata: stat, directory: FullDiskDirectory, package: Bool, writable: Bool) throws {
        coverage.regularFiles += 1
        let bytes = max(0, Int64(metadata.st_size)), identity = MalwareFiles.identity(metadata)
        let (sum, overflow) = coverage.logicalBytes.addingReportingOverflow(bytes)
        if overflow { coverage.logicalBytes = Int64.max; coverage.incomplete = true }
        else { coverage.logicalBytes = sum }
        try traversal?.recordPolicy(path: path, metadata: metadata, writable: writable, package: package)
        try candidates?.append(path: path, rootPath: directory.root, identity: identity, bytes: bytes)
        let old = identity.modified < started.timeIntervalSince1970 - 365 * 24 * 60 * 60
        if bytes >= threshold || old {
            let policy = FullDiskFilePolicy(writable: writable, package: package, owner: UInt64(metadata.st_uid))
            let actionable = canProcess(path, scope: directory.root, policy: policy)
            let reason = actionable ? "常规个人文件，仍须逐项确认。" : "只读发现：系统、应用包、他人文件、受保护目录或不可写卷不提供清理。"
            try largeStore?.append(.init(path: path, category: bytes >= threshold ? "大文件" : "旧文件（超过一年）", bytes: bytes,
                                         detail: reason, canTrash: actionable, identity: identity, scopeRoot: directory.root))
        }
    }
    func inPackage(_ path: String) -> Bool {
        path.split(separator: "/").contains { packageComponent(String($0)) }
    }
    func packageComponent(_ name: String) -> Bool {
        name == ".git" || ["app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "photoslibrary", "photolibrary", "musiclibrary", "pages", "numbers", "key"].contains((name as NSString).pathExtension.lowercased())
    }
    func canProcess(_ path: String, scope: String, policy: FullDiskFilePolicy) -> Bool {
        guard policy.owner == UInt64(getuid()), policy.writable, !policy.package, path != scope,
              FileSafety.contains(scope, path), !ignored(path), !FileSafety.isProtected(URL(fileURLWithPath: path), home: home) else { return false }
        if FileSafety.contains(home.path, path), home.path != "/" {
            let relative = path.dropFirst(home.path.count).split(separator: "/")
            guard relative.first != "Library", relative.first != "Applications", !relative.contains(where: { $0.hasPrefix(".") }) else { return false }
            return true
        }
        let systemParents = ["/System", "/bin", "/sbin", "/usr", "/Library", "/Applications", "/private", "/Users", "/dev", "/Network"]
        return scope != "/" && !systemParents.contains { FileSafety.contains($0, path) }
    }
    func hash(_ path: String, identity: FileIdentity) throws -> String? {
        try checkCancellation()
        if !hashingBegan { hashingBegan = true; updateProgress("SHA-256：" + path, force: true); try checkCancellation() }
        let url = URL(fileURLWithPath: path)
        do {
            let parent = try ScanOwnedLocation.openDirectory(url.deletingLastPathComponent(), searchAncestors: true); defer { close(parent) }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw FullDiskReadError.io("打开内容以校验", errno) }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0 else { throw FullDiskReadError.io("读取打开文件属性", errno) }
            guard before.st_mode & S_IFMT == S_IFREG, before.st_flags & UInt32(SF_DATALESS) == 0,
                  MalwareFiles.identity(before) == identity else { throw FullDiskReadError.changed("校验前身份变化或不是已下载常规文件") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var digest = SHA256()
            while true {
                let bytes = try autoreleasepool { () throws -> Int in
                    try checkCancellation()
                    let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                    if !data.isEmpty { digest.update(data: data); updateProgress("SHA-256：" + path) }
                    return data.count
                }
                if bytes == 0 { break }
            }
            var after = stat(), pathNow = stat()
            guard fstat(fd, &after) == 0, fstatat(parent, url.lastPathComponent, &pathNow, AT_SYMLINK_NOFOLLOW) == 0,
                  MalwareFiles.identity(after) == identity, MalwareFiles.identity(pathNow) == identity,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  after.st_flags & UInt32(SF_DATALESS) == 0 else { throw FullDiskReadError.changed("校验期间内容或身份变化") }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch FullDiskReadError.cancelled { throw FullDiskReadError.cancelled }
        catch FullDiskReadError.io(let stage, let code) { try failure(path, stage, code); return nil }
        catch FullDiskReadError.changed(let detail) { try failure(path, "内容身份校验", ESTALE, detail: detail); return nil }
        catch {
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = error.domain == NSPOSIXErrorDomain ? Int32(error.code) : underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying!.code) : EIO
            try failure(path, "SHA-256读取", code, detail: error.localizedDescription); return nil
        }
    }
    func findDuplicates() throws {
        guard let candidates, let traversal else { return }
        try candidates.flush()
        try candidates.forEachDuplicateSizeCandidate(shouldStop: { self.cancellation.isCancelled }) { item in
            try checkCancellation()
            if let digest = try hash(item.path, identity: item.identity) { try candidates.recordDigest(path: item.path, digest: digest, identity: item.identity) }
        }
        try candidates.flush()
        var group = "", keeperVerified = false, keeperPublished = false
        var pendingKeeper: ScanItem?
        try candidates.forEachDuplicateGroupItem(shouldStop: { self.cancellation.isCancelled }) { item in
            try checkCancellation()
            let key = item.groupDigest + ":" + String(item.bytes)
            if group != key {
                group = key; keeperVerified = try hash(item.keeperPath, identity: item.keeperIdentity) == item.groupDigest
                pendingKeeper = nil; keeperPublished = false
            }
            guard keeperVerified else { return }
            if !item.isKeeper { guard try hash(item.path, identity: item.identity) == item.groupDigest else { return } }
            guard FileSafety.identity(URL(fileURLWithPath: item.keeperPath)) == item.keeperIdentity,
                  FileSafety.identity(URL(fileURLWithPath: item.path)) == item.identity else {
                try failure(item.path, "重复组最终身份变化", ESTALE); return
            }
            let policy = try traversal.policy(item.path)
            let actionable = !item.isKeeper && policy.map { canProcess(item.path, scope: item.rootPath, policy: $0) } == true
            let result = ScanItem(path: item.path, category: item.isKeeper ? "保留原件" : "重复副本", bytes: item.bytes,
                                             detail: item.isKeeper ? "此组固定保留一份，不提供清理。" : actionable ? "完整SHA-256一致；仍需逐项确认，处理时再次核对保留项。" : "完整SHA-256一致；此文件属于只读范围，不提供清理。",
                                             group: item.groupDigest, canTrash: actionable, identity: item.identity, scopeRoot: item.rootPath,
                                             retainedPath: item.keeperPath, retainedIdentity: item.keeperIdentity)
            if item.isKeeper { pendingKeeper = result }
            else {
                // A lone keeper is not a duplicate group when every counterpart
                // changed or became unreadable during final verification.
                if !keeperPublished, let pendingKeeper { try duplicateStore?.append(pendingKeeper); keeperPublished = true }
                try duplicateStore?.append(result)
            }
        }
    }
    func finish() -> FullDiskFileReport {
        coverage.cancelled = coverage.cancelled || cancellation.isCancelled
        if coverage.cancelled { coverage.incomplete = true; fatal = .cancelled }
        do { try traversal?.dispose() }
        catch { coverage.incomplete = true; coverage.notes.append("私有遍历索引清理失败：" + error.localizedDescription) }
        do { try candidates?.dispose() }
        catch { coverage.incomplete = true; coverage.notes.append("私有候选索引清理失败：" + error.localizedDescription) }
        func complete(_ store: ScanResultStore?, _ original: ScanReport) -> ScanReport {
            var report = original
            if let store {
                do {
                    try store.flush(); let page = try store.page(limit: 200)
                    report.items = page.items; report.totalItemCount = page.statistics.totalCount
                    report.processableItemCount = page.statistics.processableCount; report.allItemsBytes = page.statistics.totalBytes
                } catch { coverage.incomplete = true; fatal = .storageError; coverage.notes.append("部分结果无法读取：" + error.localizedDescription) }
            }
            report.finishedAt = Date(); report.visitedFiles = coverage.visitedEntries; report.peakResidentBytes = peakRSS
            report.resultLimit = 200; report.truncated = coverage.incomplete; report.stopReason = fatal
            report.warnings = ["全盘文件发现包括只读范围；不代表所有文件都可清理。", "未访问路径和跳过原因保存在覆盖问题清单中。"]
            return report
        }
        large = complete(largeStore, large); duplicates = complete(duplicateStore, duplicates)
        do { try issues?.flush(); coverage.issueCount = try issues?.statistics().totalCount ?? 0 }
        catch { coverage.incomplete = true; fatal = .storageError; coverage.notes.append("覆盖问题清单无法完整写入：" + error.localizedDescription) }
        large.truncated = coverage.incomplete; duplicates.truncated = coverage.incomplete
        large.stopReason = fatal; duplicates.stopReason = fatal
        updateProgress("全盘文件检查结束", force: true)
        return .init(largeFiles: large, duplicates: duplicates, coverage: coverage)
    }
}
