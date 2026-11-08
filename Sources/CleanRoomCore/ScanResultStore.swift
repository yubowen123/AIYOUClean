import Foundation
import Darwin
import CSQLite

public struct ScanResultReference: Codable, Sendable, Equatable {
    public let path: String
    public let sessionID: String
    public init(path: String, sessionID: String) { self.path = path; self.sessionID = sessionID }
}
public struct ScanResultStatistics: Sendable {
    public let totalCount: Int
    public let processableCount: Int
    public let totalBytes: Int64
    public let processableBytes: Int64
    public let maximumBytes: Int64
}
public struct ScanResultPage: Sendable {
    public let items: [ScanItem]
    public let filteredCount: Int
    public let statistics: ScanResultStatistics
}
public enum ScanStoreError: LocalizedError {
    case rejected(String), cancelled
    public var errorDescription: String? {
        switch self { case .rejected(let message): return message; case .cancelled: return "落盘结果查询已取消。" }
    }
}

// Foundation standardization may rewrite /private/var into its /var symlink
// alias. Source metadata must preserve the literal path used by no-follow I/O.
enum ScanLexicalPath {
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(component) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

// Shared implementation for result/candidate stores. Only canonical system-temp
// UUID sessions of this schema are accepted; references never grant source-file deletion.
struct ScanOwnedLocation {
    enum Kind: String { case results, candidates }
    let directory: URL, file: URL, id: String, kind: Kind
    var reference: ScanResultReference { ScanResultReference(path: file.path, sessionID: id) }
    static var base: URL {
        let original = FileManager.default.temporaryDirectory
        guard let canonical = realpath(original.path, nil) else { return original }
        defer { free(canonical) }
        // Foundation standardization rewrites /private/var back to /var on
        // macOS. Keep realpath's literal no-symlink spelling for fd traversal.
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }
    static func openDirectory(_ url: URL, searchAncestors: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ScanStoreError.rejected("需要本地绝对目录。") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScanStoreError.rejected("无法打开根目录。") }
        do {
            let components = Array(url.pathComponents.dropFirst())
            for (index, component) in components.enumerated() {
                guard component != ".", component != "..", !component.utf8.contains(0) else { throw ScanStoreError.rejected("目录分量无效。") }
                let accessMode = searchAncestors && index < components.count - 1 ? O_SEARCH : O_RDONLY
                let next = openat(fd, component, accessMode | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ScanStoreError.rejected("目录含链接或无法访问。") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func derive(_ reference: ScanResultReference, kind: Kind) throws -> ScanOwnedLocation {
        guard let uuid = UUID(uuidString: reference.sessionID), uuid.uuidString == reference.sessionID else { throw ScanStoreError.rejected("结果会话ID无效。") }
        let directory = base.appendingPathComponent("AIYOUClean-\(kind.rawValue)-\(uuid.uuidString)")
        let file = directory.appendingPathComponent(kind.rawValue + ".sqlite3")
        guard reference.path == file.path else { throw ScanStoreError.rejected("结果引用不是本模块的独立临时数据库。") }
        return ScanOwnedLocation(directory: directory, file: file, id: uuid.uuidString, kind: kind)
    }
    static func create(_ kind: Kind) throws -> ScanOwnedLocation {
        let id = UUID().uuidString
        let directory = base.appendingPathComponent("AIYOUClean-\(kind.rawValue)-\(id)")
        let location = ScanOwnedLocation(directory: directory, file: directory.appendingPathComponent(kind.rawValue + ".sqlite3"), id: id, kind: kind)
        let baseFD = try openDirectory(base); defer { close(baseFD) }
        guard mkdirat(baseFD, directory.lastPathComponent, 0o700) == 0 else { throw ScanStoreError.rejected("无法建立私有存储目录。") }
        let directoryFD = openat(baseFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ScanStoreError.rejected("无法打开私有存储目录。") }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, location.file.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { _ = unlinkat(baseFD, directory.lastPathComponent, AT_REMOVEDIR); throw ScanStoreError.rejected("无法建立私有落盘数据库。") }
        close(fd); return location
    }
    func validateFiles() throws {
        var directoryStat = stat(), fileStat = stat()
        guard lstat(directory.path, &directoryStat) == 0, directoryStat.st_mode & S_IFMT == S_IFDIR, directoryStat.st_uid == getuid(), directoryStat.st_mode & 0o777 == 0o700,
              lstat(file.path, &fileStat) == 0, fileStat.st_mode & S_IFMT == S_IFREG, fileStat.st_uid == getuid(), fileStat.st_mode & 0o777 == 0o600, fileStat.st_nlink == 1 else { throw ScanStoreError.rejected("结果目录/文件归属、权限或硬链接数不符合私有存储约定。") }
        let parent = try Self.openDirectory(directory); defer { close(parent) }
        try inspectChildren(parent)
    }
    private func inspectChildren(_ parent: Int32) throws {
        guard let stream = fdopendir(dup(parent)) else { throw ScanStoreError.rejected("无法检查结果目录。") }; defer { closedir(stream) }
        let allowed = Set([file.lastPathComponent, file.lastPathComponent + "-journal", file.lastPathComponent + "-wal", file.lastPathComponent + "-shm"])
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            var metadata = stat()
            guard allowed.contains(name), fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1 else { throw ScanStoreError.rejected("结果目录含未知文件、链接或非本模块内容，拒绝使用/删除。") }
        }
    }
    func removeArtifacts() throws {
        try validateFiles()
        let parent = try Self.openDirectory(directory); defer { close(parent) }
        try inspectChildren(parent) // Validate everything before deleting the first file.
        for name in [file.lastPathComponent + "-journal", file.lastPathComponent + "-wal", file.lastPathComponent + "-shm", file.lastPathComponent] {
            var metadata = stat()
            if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { continue }; throw ScanStoreError.rejected("无法核对私有存储文件。") }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1, unlinkat(parent, name, 0) == 0 else { throw ScanStoreError.rejected("私有存储删除失败，未递归删除其他内容。") }
        }
        guard rmdir(directory.path) == 0 else { throw ScanStoreError.rejected("私有存储目录仍有内容，未递归清空。") }
    }
}

private final class ScanSQLiteCancellation {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}
final class ScanSQLiteConnection {
    let location: ScanOwnedLocation
    let readOnly: Bool
    private(set) var pointer: OpaquePointer?
    private var pendingWrites = 0
    var writeBatchSize = 200
    private(set) var writeGeneration = 0
    init(location: ScanOwnedLocation, readOnly: Bool, creating: Bool = false) throws {
        self.location = location; self.readOnly = readOnly
        try location.validateFiles()
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(location.file.path, &pointer, flags, nil) == SQLITE_OK else { let message = errorText; sqlite3_close(pointer); pointer = nil; throw ScanStoreError.rejected(message) }
        do {
            sqlite3_busy_timeout(pointer, 2000)
            // Extension loading is disabled by default. Apple's SDK omits the
            // enabling API, and this module never enables extensions.
            sqlite3_limit(pointer, SQLITE_LIMIT_LENGTH, 4 * 1024 * 1024)
            try execute("PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA trusted_schema=OFF;")
            if readOnly { try execute("PRAGMA query_only=ON;") }
            if creating {
                try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL; PRAGMA application_id=1095320402; PRAGMA user_version=1; CREATE TABLE scan_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);")
                for (key, value) in [("module", "AIYOUClean.ScanStore"), ("schema", "1"), ("session", location.id), ("kind", location.kind.rawValue)] {
                    let statement = try prepare("INSERT INTO scan_meta(key,value) VALUES(?,?)"); try statement.text(key, at: 1); try statement.text(value, at: 2); _ = try statement.step()
                }
            } else { try validateSchema() }
        } catch { sqlite3_close(pointer); pointer = nil; throw error }
    }
    deinit { if pointer != nil { try? flush(); sqlite3_close_v2(pointer) } }
    var errorText: String { pointer.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "结果数据库已关闭。" }
    func prepare(_ sql: String) throws -> ScanSQLiteStatement {
        guard let pointer else { throw ScanStoreError.rejected("结果数据库已关闭。") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ScanStoreError.rejected(errorText) }
        return ScanSQLiteStatement(statement, owner: self)
    }
    func execute(_ sql: String) throws {
        guard let pointer else { throw ScanStoreError.rejected("结果数据库已关闭。") }
        let code = sqlite3_exec(pointer, sql, nil, nil, nil)
        if code == SQLITE_INTERRUPT { throw ScanStoreError.cancelled }
        guard code == SQLITE_OK else { throw ScanStoreError.rejected(errorText) }
    }
    func requireWritable() throws { guard pointer != nil else { throw ScanStoreError.rejected("结果数据库已关闭。") }; guard !readOnly else { throw ScanStoreError.rejected("只读结果数据库拒绝修改。") } }
    func beginWrite() throws { try requireWritable(); if sqlite3_get_autocommit(pointer) != 0 { try execute("BEGIN IMMEDIATE") } }
    func didWrite() throws { pendingWrites += 1; if pendingWrites >= writeBatchSize { try flush() } }
    func rollback() { if pendingWrites > 0 || sqlite3_get_autocommit(pointer) == 0 { try? execute("ROLLBACK") }; pendingWrites = 0 }
    func flush() throws {
        if readOnly { return }
        guard pointer != nil else { throw ScanStoreError.rejected("结果数据库已关闭。") }
        if pendingWrites > 0 || sqlite3_get_autocommit(pointer) == 0 { try execute("COMMIT"); pendingWrites = 0; writeGeneration &+= 1 }
    }
    func close() throws { guard pointer != nil else { return }; try flush(); if let pointer { guard sqlite3_close(pointer) == SQLITE_OK else { throw ScanStoreError.rejected(errorText) }; self.pointer = nil } }
    func withCancellation<T>(_ check: () -> Bool, _ body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(check) { escaping in
            if escaping() { throw ScanStoreError.cancelled }
            let box = ScanSQLiteCancellation(escaping)
            sqlite3_progress_handler(pointer, 1000, { raw in
                guard let raw else { return 0 }
                return Unmanaged<ScanSQLiteCancellation>.fromOpaque(raw).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(box).toOpaque())
            defer { sqlite3_progress_handler(pointer, 0, nil, nil) }
            return try body()
        }
    }
    private func validateSchema() throws {
        let app = try prepare("PRAGMA application_id")
        guard try app.step(), app.integer(0) == 1095320402 else { throw ScanStoreError.rejected("不是AIYOUClean落盘结果数据库。") }
        let version = try prepare("PRAGMA user_version")
        guard try version.step(), version.integer(0) == 1 else { throw ScanStoreError.rejected("落盘schema版本不受支持。") }
        for (key, expected) in [("module", "AIYOUClean.ScanStore"), ("schema", "1"), ("session", location.id), ("kind", location.kind.rawValue)] {
            let statement = try prepare("SELECT value FROM scan_meta WHERE key=?"); try statement.text(key, at: 1)
            guard try statement.step(), try statement.string(0) == expected else { throw ScanStoreError.rejected("落盘结果schema或会话ID不匹配。") }
        }
    }
}
final class ScanSQLiteStatement {
    let pointer: OpaquePointer
    unowned let owner: ScanSQLiteConnection
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(_ pointer: OpaquePointer, owner: ScanSQLiteConnection) { self.pointer = pointer; self.owner = owner }
    deinit { sqlite3_finalize(pointer) }
    func reset() { sqlite3_reset(pointer); sqlite3_clear_bindings(pointer) }
    private func check(_ code: Int32) throws { guard code == SQLITE_OK else { throw ScanStoreError.rejected(owner.errorText) } }
    func text(_ value: String, at index: Int32) throws { try check(sqlite3_bind_text(pointer, index, value, -1, transient)) }
    func integer(_ value: Int64, at index: Int32) throws { try check(sqlite3_bind_int64(pointer, index, value)) }
    func double(_ value: Double, at index: Int32) throws { try check(sqlite3_bind_double(pointer, index, value)) }
    func blob(_ value: Data, at index: Int32) throws { try value.withUnsafeBytes { try check(sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32($0.count), transient)) } }
    func step() throws -> Bool {
        let code = sqlite3_step(pointer)
        if code == SQLITE_ROW { return true }; if code == SQLITE_DONE { return false }; if code == SQLITE_INTERRUPT { throw ScanStoreError.cancelled }
        throw ScanStoreError.rejected(owner.errorText)
    }
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(pointer, index) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(pointer, index) }
    func string(_ index: Int32) throws -> String { guard let value = sqlite3_column_text(pointer, index) else { throw ScanStoreError.rejected("落盘结果文本损坏。") }; return String(cString: value) }
    func data(_ index: Int32) throws -> Data {
        let bytes = sqlite3_column_bytes(pointer, index)
        guard bytes >= 0, bytes <= 1_048_576, let value = sqlite3_column_blob(pointer, index) else { throw ScanStoreError.rejected("落盘JSON损坏或过大。") }
        return Data(bytes: value, count: Int(bytes))
    }
}

public final class ScanResultStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let database: ScanSQLiteConnection
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    // Only fixed hot-path statements are retained, never per-path SQL.
    private var statements: [String: ScanSQLiteStatement] = [:]
    private var ancestorMemo: (parent: String, exists: Bool, generation: Int)?
    private var pagingIndexesDeferred = false
    public var reference: ScanResultReference { database.location.reference }
    public static func createTemporary(deferQueryIndexes: Bool = false) throws -> ScanResultStore {
        let location = try ScanOwnedLocation.create(.results)
        do { return try ScanResultStore(database: ScanSQLiteConnection(location: location, readOnly: false, creating: true), creating: true, deferQueryIndexes: deferQueryIndexes) }
        catch { try? location.removeArtifacts(); throw error }
    }
    public convenience init(reference: ScanResultReference, readOnly: Bool = true) throws {
        try self.init(database: ScanSQLiteConnection(location: ScanOwnedLocation.derive(reference, kind: .results), readOnly: readOnly), creating: false)
    }
    private init(database: ScanSQLiteConnection, creating: Bool, deferQueryIndexes: Bool = false) throws {
        self.database = database
        if creating {
            pagingIndexesDeferred = true
            if deferQueryIndexes { database.writeBatchSize = 2048 }
            try database.execute("""
            CREATE TABLE scan_items(sequence INTEGER PRIMARY KEY,id TEXT NOT NULL UNIQUE,path TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),can_trash INTEGER NOT NULL CHECK(can_trash IN(0,1)),search_text TEXT NOT NULL,payload BLOB NOT NULL CHECK(length(payload)<=1048576));
            CREATE INDEX scan_items_path ON scan_items(path,id);
            CREATE INDEX scan_items_maximum ON scan_items(bytes DESC);
            CREATE TABLE scan_statistics(singleton INTEGER PRIMARY KEY CHECK(singleton=1),total_count INTEGER NOT NULL,processable_count INTEGER NOT NULL,total_bytes INTEGER NOT NULL,processable_bytes INTEGER NOT NULL,maximum_bytes INTEGER NOT NULL);
            INSERT INTO scan_statistics VALUES(1,0,0,0,0,0);
            CREATE TRIGGER scan_insert AFTER INSERT ON scan_items BEGIN
              SELECT CASE WHEN (SELECT total_bytes FROM scan_statistics WHERE singleton=1)>9223372036854775807-NEW.bytes THEN RAISE(ABORT,'logical byte total overflow') END;
              UPDATE scan_statistics SET total_count=total_count+1,processable_count=processable_count+NEW.can_trash,total_bytes=total_bytes+NEW.bytes,processable_bytes=processable_bytes+NEW.bytes*NEW.can_trash,maximum_bytes=max(maximum_bytes,NEW.bytes) WHERE singleton=1;
            END;
            CREATE TRIGGER scan_delete AFTER DELETE ON scan_items BEGIN
              UPDATE scan_statistics SET total_count=total_count-1,processable_count=processable_count-OLD.can_trash,total_bytes=total_bytes-OLD.bytes,processable_bytes=processable_bytes-OLD.bytes*OLD.can_trash,maximum_bytes=coalesce((SELECT bytes FROM scan_items ORDER BY bytes DESC LIMIT 1),0) WHERE singleton=1;
            END;
            """)
            if !deferQueryIndexes { try createPagingIndexes() }
        } else {
            for table in ["scan_items", "scan_statistics"] {
                let type = try database.prepare("SELECT type FROM sqlite_master WHERE name=?"); try type.text(table, at: 1)
                guard try type.step(), try type.string(0) == "table" else { throw ScanStoreError.rejected("结果schema缺少受支持的数据表。") }
            }
            _ = try database.prepare("SELECT sequence,id,path,bytes,can_trash,search_text,payload FROM scan_items LIMIT 0")
            _ = try database.prepare("SELECT total_count,processable_count,total_bytes,processable_bytes,maximum_bytes FROM scan_statistics LIMIT 0")
        }
    }
    private func createPagingIndexes() throws {
        guard pagingIndexesDeferred else { return }
        try database.execute("CREATE INDEX IF NOT EXISTS scan_items_size ON scan_items(bytes DESC,path,id)")
        try database.execute("CREATE INDEX IF NOT EXISTS scan_items_processable ON scan_items(can_trash,bytes DESC,path,id)")
        try database.execute("DROP INDEX IF EXISTS scan_items_maximum")
        pagingIndexesDeferred = false
    }
    public func prepareForPaging(isCancelled: () -> Bool = { false }) throws {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        try database.withCancellation(isCancelled) { try createPagingIndexes() }
    }
    private func cached<T>(_ sql: String, _ body: (ScanSQLiteStatement) throws -> T) throws -> T {
        let statement: ScanSQLiteStatement
        if let value = statements[sql] { statement = value }
        else { statement = try database.prepare(sql); statements[sql] = statement }
        defer { statement.reset() }
        return try body(statement)
    }
    private func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 32768 else { throw ScanStoreError.rejected("结果路径无效或过大。") }
        return ScanLexicalPath.normalize(path)
    }
    public func append(_ item: ScanItem) throws {
        lock.lock(); defer { lock.unlock() }
        try appendLocked(item)
    }
    private func appendLocked(_ item: ScanItem) throws {
        try database.requireWritable()
        guard item.bytes >= 0 else { throw ScanStoreError.rejected("结果逻辑大小不能为负数。") }
        let path = try normalized(item.path), payload = try encoder.encode(item)
        guard payload.count <= 1_048_576 else { throw ScanStoreError.rejected("单条结果JSON超过1MiB。") }
        let search = (item.name + "\n" + item.path + "\n" + item.category + "\n" + item.detail).lowercased()
        try database.beginWrite()
        do {
            try cached("INSERT OR IGNORE INTO scan_items(id,path,bytes,can_trash,search_text,payload) VALUES(?,?,?,?,?,?)") { statement in
                try statement.text(item.id, at: 1); try statement.text(path, at: 2); try statement.integer(item.bytes, at: 3); try statement.integer(item.canTrash ? 1 : 0, at: 4); try statement.text(search, at: 5); try statement.blob(payload, at: 6); _ = try statement.step()
            }
            if let memo = ancestorMemo, FileSafety.contains(path, memo.parent) { ancestorMemo = nil }
            try database.didWrite()
        } catch { throw error }
    }
    public func flush() throws { lock.lock(); defer { lock.unlock() }; try database.flush() }
    public func statistics() throws -> ScanResultStatistics {
        lock.lock(); defer { lock.unlock() }
        try database.flush()
        let statement = try database.prepare("SELECT total_count,processable_count,total_bytes,processable_bytes,maximum_bytes FROM scan_statistics WHERE singleton=1")
        guard try statement.step() else { throw ScanStoreError.rejected("结果统计缺失。") }
        return ScanResultStatistics(totalCount: Int(statement.integer(0)), processableCount: Int(statement.integer(1)), totalBytes: statement.integer(2), processableBytes: statement.integer(3), maximumBytes: statement.integer(4))
    }
    public func page(offset: Int = 0, limit: Int = 200, query: String = "", largestFirst: Bool = true, processableOnly: Bool = false, isCancelled: () -> Bool = { false }) throws -> ScanResultPage {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        guard query.utf8.count <= 4096 else { throw ScanStoreError.rejected("搜索词过长。") }
        return try database.withCancellation(isCancelled) {
            try createPagingIndexes()
            let statistics = try self.statistics()
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let filter = (processableOnly ? "can_trash=1" : "1") + (query.isEmpty ? "" : " AND instr(search_text,?)>0")
            let countStatement = try database.prepare("SELECT count(*) FROM scan_items WHERE " + filter)
            if !query.isEmpty { try countStatement.text(query, at: 1) }
            guard try countStatement.step() else { throw ScanStoreError.rejected("无法读取搜索计数。") }
            let count = Int(countStatement.integer(0)), order = largestFirst ? "bytes DESC,path,id" : "path,id"
            let statement = try database.prepare("SELECT payload FROM scan_items WHERE " + filter + " ORDER BY " + order + " LIMIT ? OFFSET ?")
            var position: Int32 = 1
            if !query.isEmpty { try statement.text(query, at: position); position += 1 }
            try statement.integer(Int64(min(200, max(0, limit))), at: position); try statement.integer(Int64(max(0, offset)), at: position + 1)
            var items: [ScanItem] = []
            while try statement.step() {
                try autoreleasepool { items.append(try decoder.decode(ScanItem.self, from: statement.data(0))) }
            }
            return ScanResultPage(items: items, filteredCount: count, statistics: statistics)
        }
    }
    public func forEachItem(processableOnly: Bool = false, isCancelled: () -> Bool = { false }, _ body: (ScanItem) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        try database.withCancellation(isCancelled) {
            let maximum = try database.prepare("SELECT coalesce(max(sequence),0) FROM scan_items"); _ = try maximum.step()
            // Stream the sequence primary key. Choosing can_trash's size index
            // would sort every matching JSON payload before delivering row one.
            let statement = try database.prepare("SELECT payload FROM scan_items NOT INDEXED WHERE sequence<=?" + (processableOnly ? " AND can_trash=1" : "") + " ORDER BY sequence")
            try statement.integer(maximum.integer(0), at: 1)
            while try statement.step() { try autoreleasepool { try body(decoder.decode(ScanItem.self, from: statement.data(0))) } }
        }
    }
    public func appendIfNoOverlap(_ item: ScanItem) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; try database.requireWritable()
        // The parent memo is valid only inside our write transaction. Another
        // writer cannot insert an ancestor between validation and insertion.
        try database.beginWrite()
        let path = try normalized(item.path)
        if try ancestorExists(path) { return false }
        if try descendantExists(path) { return false }
        try appendLocked(item); return true
    }
    private func exactExists(_ path: String) throws -> Bool {
        try cached("SELECT 1 FROM scan_items WHERE path=? LIMIT 1") { statement in
            try statement.text(path, at: 1); return try statement.step()
        }
    }
    private func descendantExists(_ path: String) throws -> Bool {
        let prefix = path == "/" ? "/" : path + "/", upper = path == "/" ? "0" : path + "0"
        return try cached("SELECT 1 FROM scan_items WHERE path>=? AND path<? LIMIT 1") { statement in
            try statement.text(prefix, at: 1); try statement.text(upper, at: 2); return try statement.step()
        }
    }
    public func containsDescendantOrSame(_ path: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let path = try normalized(path)
        return try exactExists(path) || descendantExists(path)
    }
    private func ancestors(_ path: String, _ body: (String) throws -> Void) rethrows {
        var current = path
        while true {
            try body(current); if current == "/" { break }
            if let slash = current.lastIndex(of: "/"), slash != current.startIndex { current = String(current[..<slash]) } else { current = "/" }
        }
    }
    private func ancestorExists(_ path: String) throws -> Bool {
        if try exactExists(path) { return true }
        let parent = path == "/" ? "/" : String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
        let normalizedParent = parent.isEmpty ? "/" : parent
        if let memo = ancestorMemo, memo.generation == database.writeGeneration,
           memo.parent.utf8.elementsEqual(normalizedParent.utf8) { return memo.exists }
        var exists = false
        try ancestors(normalizedParent) { candidate in
            if exists { return }
            exists = try exactExists(candidate)
        }
        ancestorMemo = (normalizedParent, exists, database.writeGeneration)
        return exists
    }
    public func removeAncestors(of path: String) throws {
        lock.lock(); defer { lock.unlock() }; try database.requireWritable()
        let path = try normalized(path); try database.beginWrite()
        ancestorMemo = nil
        do {
            try ancestors(path) { ancestor in
                try cached("DELETE FROM scan_items WHERE path=?") { statement in try statement.text(ancestor, at: 1); _ = try statement.step() }
            }
            try database.didWrite()
        } catch { throw error }
    }
    /// Reconcile acknowledged filesystem operations with this scan snapshot.
    /// This only edits catalogue rows; it never removes source files. Keep the
    /// whole batch atomic and do not coalesce canonically equivalent UTF8 keys.
    public func removeProcessedPaths(_ paths: [String]) throws -> ScanResultStatistics {
        lock.lock(); defer { lock.unlock() }; try database.requireWritable()
        let keys = try paths.map { value -> String in
            let path = try normalized(value)
            guard path != "/" else { throw ScanStoreError.rejected("不能将磁盘根作为已处理项目移除。") }
            return path
        }
        guard !keys.isEmpty else { return try statistics() }
        try database.flush(); try database.beginWrite(); ancestorMemo = nil
        do {
            for path in keys {
                try cached("DELETE FROM scan_items WHERE path=? OR (path>=? AND path<?)") { statement in
                    try statement.text(path, at: 1); try statement.text(path + "/", at: 2); try statement.text(path + "0", at: 3)
                    _ = try statement.step()
                }
            }
            // No didWrite() here: its periodic commit would split this batch.
            try database.flush()
            return try statistics()
        } catch {
            database.rollback(); ancestorMemo = nil
            throw error
        }
    }
    public static func remove(_ reference: ScanResultReference) throws {
        let location = try ScanOwnedLocation.derive(reference, kind: .results)
        var st = stat()
        if lstat(location.directory.path, &st) != 0, errno == ENOENT { return }
        let validation = try ScanResultStore(reference: reference, readOnly: true)
        try validation.database.close(); try location.removeArtifacts()
    }
}
