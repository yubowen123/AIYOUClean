import Foundation
import Darwin
import CSQLite

public struct SpaceLensStatistics: Sendable {
    public let totalCount: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let incompleteCount: Int
}
public struct SpaceLensPage: Sendable {
    public let items: [SpaceLensItem]
    public let totalCount: Int
}
public struct SpaceLensMapData: Sendable {
    public let items: [SpaceLensItem]
    public let remainingCount: Int
    public let remainingBytes: Int64
}

/// Owned SQLite sessions share the Core storage location validation, but have a
/// distinct space-lens schema. Paths never authorize removal of source files.
public final class SpaceLensResultStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let database: ScanSQLiteConnection
    public var reference: ScanResultReference { database.location.reference }
    static func create() throws -> SpaceLensResultStore {
        let location = try ScanOwnedLocation.create(.results)
        do { return try SpaceLensResultStore(database: ScanSQLiteConnection(location: location, readOnly: false, creating: true), creating: true) }
        catch { try? location.removeArtifacts(); throw error }
    }
    public convenience init(reference: ScanResultReference, readOnly: Bool = true) throws {
        try self.init(database: ScanSQLiteConnection(location: ScanOwnedLocation.derive(reference, kind: .results), readOnly: readOnly), creating: false)
    }
    private init(database: ScanSQLiteConnection, creating: Bool) throws {
        self.database = database
        if creating {
            try database.execute("""
            CREATE TABLE lens_meta(version INTEGER NOT NULL); INSERT INTO lens_meta VALUES(1);
            CREATE TABLE lens_items(path TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL,logical INTEGER,allocated INTEGER,files INTEGER NOT NULL,directories INTEGER NOT NULL,excluded INTEGER NOT NULL,hardlinks INTEGER NOT NULL);
            CREATE INDEX lens_logical ON lens_items(logical DESC,path);
            CREATE INDEX lens_allocated ON lens_items(allocated DESC,path);
            CREATE TABLE lens_directories(device INTEGER NOT NULL,inode INTEGER NOT NULL,PRIMARY KEY(device,inode));
            CREATE TABLE lens_hardlinks(device INTEGER NOT NULL,inode INTEGER NOT NULL,owner TEXT NOT NULL,logical INTEGER NOT NULL,allocated INTEGER NOT NULL,PRIMARY KEY(device,inode));
            CREATE TABLE lens_pending(sequence INTEGER PRIMARY KEY,path TEXT NOT NULL UNIQUE);
            """)
        } else {
            let schema = try database.prepare("SELECT version FROM lens_meta")
            guard try schema.step(), schema.integer(0) == 1 else { throw ScanStoreError.rejected("空间分析存储版本无效。") }
        }
    }
    func flush() throws { lock.lock(); defer { lock.unlock() }; try database.flush() }
    func save(_ item: SpaceLensItem) throws {
        lock.lock(); defer { lock.unlock() }; try database.beginWrite()
        let statement = try database.prepare("INSERT OR REPLACE INTO lens_items VALUES(?,?,?,?,?,?,?,?,?,?)")
        try statement.text(item.path, at: 1); try statement.text(item.name, at: 2); try statement.text(item.kind.rawValue, at: 3); try statement.text(item.state.rawValue, at: 4)
        if let value = item.logicalBytes { try statement.integer(value, at: 5) }
        if let value = item.allocatedBytes { try statement.integer(value, at: 6) }
        try statement.integer(Int64(item.fileCount), at: 7); try statement.integer(Int64(item.directoryCount), at: 8)
        try statement.integer(Int64(item.excludedEntries), at: 9); try statement.integer(Int64(item.duplicateHardLinks), at: 10)
        _ = try statement.step(); try database.didWrite()
    }
    func markDirectory(device: UInt64, inode: UInt64) throws -> Bool {
        try database.beginWrite()
        let statement = try database.prepare("INSERT OR IGNORE INTO lens_directories VALUES(?,?)")
        try statement.integer(Int64(bitPattern: device), at: 1); try statement.integer(Int64(bitPattern: inode), at: 2)
        _ = try statement.step(); let inserted = sqlite3_changes(database.pointer) == 1
        try database.didWrite(); return inserted
    }
    func enqueue(_ path: String) throws {
        try database.beginWrite(); let statement = try database.prepare("INSERT OR IGNORE INTO lens_pending(path) VALUES(?)")
        try statement.text(path, at: 1); _ = try statement.step(); try database.didWrite()
    }
    func popDirectory() throws -> String? {
        let statement = try database.prepare("SELECT sequence,path FROM lens_pending ORDER BY sequence LIMIT 1")
        guard try statement.step() else { return nil }
        let sequence = statement.integer(0), path = try statement.string(1)
        try database.beginWrite(); let remove = try database.prepare("DELETE FROM lens_pending WHERE sequence=?")
        try remove.integer(sequence, at: 1); _ = try remove.step(); try database.didWrite(); return path
    }
    /// Returns false for a duplicate. Ownership is deterministic across direct
    /// children, without retaining a dictionary entry for every inode in RAM.
    func accountHardLink(device: UInt64, inode: UInt64, owner: String, logical: Int64, allocated: Int64) throws -> (counted: Bool, duplicate: Bool) {
        let statement = try database.prepare("SELECT owner,logical,allocated FROM lens_hardlinks WHERE device=? AND inode=?")
        try statement.integer(Int64(bitPattern: device), at: 1); try statement.integer(Int64(bitPattern: inode), at: 2)
        if try statement.step() {
            let previousOwner = try statement.string(0)
            guard owner < previousOwner else { return (false, true) }
            let oldLogical = statement.integer(1), oldAllocated = statement.integer(2)
            try database.beginWrite()
            let adjust = try database.prepare("UPDATE lens_items SET logical=max(0,logical-?),allocated=max(0,allocated-?),hardlinks=hardlinks+1 WHERE path=?")
            try adjust.integer(oldLogical, at: 1); try adjust.integer(oldAllocated, at: 2); try adjust.text(previousOwner, at: 3); _ = try adjust.step()
            let move = try database.prepare("UPDATE lens_hardlinks SET owner=? WHERE device=? AND inode=?")
            try move.text(owner, at: 1); try move.integer(Int64(bitPattern: device), at: 2); try move.integer(Int64(bitPattern: inode), at: 3); _ = try move.step()
            try database.didWrite(); return (true, true)
        }
        try database.beginWrite()
        let insert = try database.prepare("INSERT INTO lens_hardlinks VALUES(?,?,?,?,?)")
        try insert.integer(Int64(bitPattern: device), at: 1); try insert.integer(Int64(bitPattern: inode), at: 2); try insert.text(owner, at: 3)
        try insert.integer(logical, at: 4); try insert.integer(allocated, at: 5); _ = try insert.step(); try database.didWrite(); return (true, false)
    }
    private func decode(_ statement: ScanSQLiteStatement) throws -> SpaceLensItem {
        guard let kind = SpaceLensItemKind(rawValue: try statement.string(2)), let state = SpaceLensItemState(rawValue: try statement.string(3)) else { throw ScanStoreError.rejected("空间分析项目状态损坏。") }
        return SpaceLensItem(path: try statement.string(0), name: try statement.string(1), kind: kind, state: state,
                             logicalBytes: sqlite3_column_type(statement.pointer, 4) == SQLITE_NULL ? nil : statement.integer(4),
                             allocatedBytes: sqlite3_column_type(statement.pointer, 5) == SQLITE_NULL ? nil : statement.integer(5),
                             fileCount: Int(statement.integer(6)), directoryCount: Int(statement.integer(7)), excludedEntries: Int(statement.integer(8)), duplicateHardLinks: Int(statement.integer(9)))
    }
    public func statistics() throws -> SpaceLensStatistics {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        let statement = try database.prepare("SELECT count(*),coalesce(sum(logical),0),coalesce(sum(allocated),0),coalesce(sum(state IN ('partial','unscanned','unreadable')),0) FROM lens_items")
        _ = try statement.step()
        return .init(totalCount: Int(statement.integer(0)), logicalBytes: statement.integer(1), allocatedBytes: statement.integer(2), incompleteCount: Int(statement.integer(3)))
    }
    public func page(offset: Int = 0, limit: Int = 200, metric: SpaceLensMetric = .allocated, isCancelled: () -> Bool = { false }) throws -> SpaceLensPage {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        return try database.withCancellation(isCancelled) {
            let count = try statistics().totalCount
            let column = metric == .allocated ? "allocated" : "logical"
            let statement = try database.prepare("SELECT * FROM lens_items ORDER BY " + column + " DESC,path LIMIT ? OFFSET ?")
            try statement.integer(Int64(min(200, max(0, limit))), at: 1); try statement.integer(Int64(max(0, offset)), at: 2)
            var items: [SpaceLensItem] = []
            while try statement.step() { try autoreleasepool { items.append(try decode(statement)) } }
            return .init(items: items, totalCount: count)
        }
    }
    public func item(path: String) throws -> SpaceLensItem? {
        lock.lock(); defer { lock.unlock() }; let statement = try database.prepare("SELECT * FROM lens_items WHERE path=?")
        try statement.text(path, at: 1); return try statement.step() ? decode(statement) : nil
    }
    public func mapData(metric: SpaceLensMetric = .allocated, maxTiles: Int = 96, isCancelled: () -> Bool = { false }) throws -> SpaceLensMapData {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        return try database.withCancellation(isCancelled) {
            let cap = min(128, max(1, maxTiles)), column = metric == .allocated ? "allocated" : "logical"
            let summary = try database.prepare("SELECT count(*),coalesce(sum(" + column + "),0) FROM lens_items WHERE " + column + ">0")
            _ = try summary.step(); let count = Int(summary.integer(0)), total = summary.integer(1)
            let statement = try database.prepare("SELECT * FROM lens_items WHERE " + column + ">0 ORDER BY " + column + " DESC,path LIMIT ?")
            try statement.integer(Int64(count > cap ? cap - 1 : cap), at: 1)
            var items: [SpaceLensItem] = [], included: Int64 = 0
            while try statement.step() { try autoreleasepool { let item = try decode(statement); items.append(item); included += metric.bytes(item) ?? 0 } }
            return .init(items: items, remainingCount: count - items.count, remainingBytes: max(0, total - included))
        }
    }
    public func forEachItem(_ body: (SpaceLensItem) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        let statement = try database.prepare("SELECT * FROM lens_items ORDER BY path")
        while try statement.step() { try autoreleasepool { try body(decode(statement)) } }
    }
    public static func remove(_ reference: ScanResultReference) throws {
        let location = try ScanOwnedLocation.derive(reference, kind: .results)
        var metadata = stat()
        if lstat(location.directory.path, &metadata) != 0, errno == ENOENT { return }
        // A lens reference has a distinct schema; generic result removal must
        // reject it. Validate this module's schema before deleting owned files.
        let validation = try SpaceLensResultStore(reference: reference, readOnly: true)
        try validation.database.close()
        try location.removeArtifacts()
    }
}
