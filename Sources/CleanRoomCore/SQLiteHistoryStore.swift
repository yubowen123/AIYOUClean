import Foundation
import CSQLite

/// Disk-backed receipts with a 2 MiB SQLite page cache. Reading the history UI
/// never decodes all prior receipts and appending never rewrites earlier rows.
final class SQLiteHistoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        let fm = FileManager.default, parent = url.deletingLastPathComponent()
        guard !FileSafety.hasSymlinkComponent(parent), !FileSafety.isSymbolicLink(url), !FileSafety.isSymbolicLink(URL(fileURLWithPath: url.path + "-wal")), !FileSafety.isSymbolicLink(URL(fileURLWithPath: url.path + "-shm")) else { throw TrashError.rejected("历史数据库路径包含符号链接") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { let text = errorText(); sqlite3_close(db); db = nil; throw TrashError.rejected(text) }
        sqlite3_busy_timeout(db, 2000)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA temp_store=FILE;")
            try execute("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, occurred REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS receipts_date_cursor ON receipts(occurred DESC,id DESC); CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func errorText() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开清理历史数据库" }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TrashError.rejected(errorText()) }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else { throw TrashError.rejected(errorText()) }; return p
    }
    func insert(_ record: TrashRecord) throws {
        let data = try JSONEncoder().encode(record)
        let p = try statement("INSERT OR IGNORE INTO receipts(id,occurred,payload) VALUES(?,?,?)"); defer { sqlite3_finalize(p) }
        sqlite3_bind_text(p, 1, record.id.uuidString, -1, transient); sqlite3_bind_double(p, 2, record.date.timeIntervalSince1970)
        let bind = data.withUnsafeBytes { sqlite3_bind_blob(p, 3, $0.baseAddress, Int32($0.count), transient) }
        guard bind == SQLITE_OK, sqlite3_step(p) == SQLITE_DONE else { throw TrashError.rejected(errorText()) }
    }
    func records(limit: Int = 200, before: TrashHistoryCursor? = nil, after: TrashHistoryCursor? = nil) throws -> [TrashRecord] {
        guard before == nil || after == nil else { throw TrashError.rejected("历史分页方向无效") }
        let cursor = before ?? after
        let query = cursor == nil ? "SELECT payload FROM receipts ORDER BY occurred DESC,id DESC LIMIT ?" : (after == nil ? "SELECT payload FROM receipts WHERE occurred < ? OR (occurred = ? AND id < ?) ORDER BY occurred DESC,id DESC LIMIT ?" : "SELECT payload FROM receipts WHERE occurred > ? OR (occurred = ? AND id > ?) ORDER BY occurred ASC,id ASC LIMIT ?")
        let p = try statement(query); defer { sqlite3_finalize(p) }
        if let cursor {
            sqlite3_bind_double(p, 1, cursor.date.timeIntervalSince1970); sqlite3_bind_double(p, 2, cursor.date.timeIntervalSince1970)
            sqlite3_bind_text(p, 3, cursor.id.uuidString, -1, transient)
        }
        sqlite3_bind_int(p, cursor == nil ? 1 : 4, Int32(min(1000, max(1, limit))))
        var result: [TrashRecord] = []
        while true {
            let code = sqlite3_step(p)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw TrashError.rejected(errorText()) }
            let value: TrashRecord = try autoreleasepool { try decode(p) }; result.append(value)
        }
        return after == nil ? result : result.reversed()
    }
    private func decode(_ p: OpaquePointer) throws -> TrashRecord {
        let count = Int(sqlite3_column_bytes(p, 0))
        guard count > 0, count <= 64 * 1024, let bytes = sqlite3_column_blob(p, 0) else { throw TrashError.rejected("恢复收据格式异常") }
        return try JSONDecoder().decode(TrashRecord.self, from: Data(bytes: bytes, count: count))
    }
    func find(_ id: UUID) throws -> TrashRecord? {
        let p = try statement("SELECT payload FROM receipts WHERE id=?"); defer { sqlite3_finalize(p) }
        sqlite3_bind_text(p, 1, id.uuidString, -1, transient)
        let code = sqlite3_step(p)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw TrashError.rejected(errorText()) }; return try decode(p)
    }
    func remove(_ id: UUID) throws {
        let p = try statement("DELETE FROM receipts WHERE id=?"); defer { sqlite3_finalize(p) }
        sqlite3_bind_text(p, 1, id.uuidString, -1, transient)
        guard sqlite3_step(p) == SQLITE_DONE else { throw TrashError.rejected(errorText()) }
    }
    /// Small legacy JSON histories are imported once without deleting the source.
    /// Larger files stay untouched for explicit offline import, avoiding an OOM.
    func migrateLegacy(_ paths: [URL]) throws -> String? {
        let p = try statement("SELECT value FROM metadata WHERE key='legacy-imported'"); let done = sqlite3_step(p) == SQLITE_ROW; sqlite3_finalize(p)
        if done { return nil }
        var warning: String?
        for url in paths where FileManager.default.fileExists(atPath: url.path) {
            guard !FileSafety.hasSymlinkComponent(url), let identity = FileSafety.identity(url), identity.size <= 10 * 1024 * 1024 else { warning = "旧版历史超过10MiB或路径异常，已保留原文件，未在启动时整体加载。"; continue }
            let records = try JSONDecoder().decode([TrashRecord].self, from: Data(contentsOf: url))
            guard records.count <= 20_000 else { warning = "旧版历史条目过多，原文件保留，需离线迁移。"; continue }
            for row in records { try insert(row) }
        }
        try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('legacy-imported','1')")
        return warning
    }
}
