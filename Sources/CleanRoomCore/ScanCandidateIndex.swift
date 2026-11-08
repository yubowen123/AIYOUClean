import Foundation
import CSQLite

public struct ScanIndexedCandidate: Sendable {
    public let path: String
    public let rootPath: String
    public let identity: FileIdentity
    public let bytes: Int64
}
public struct ScanDuplicateGroupItem: Sendable {
    public let groupDigest: String
    public let path: String
    public let rootPath: String
    public let bytes: Int64
    public let identity: FileIdentity
    public let keeperPath: String
    public let keeperIdentity: FileIdentity
    public let isKeeper: Bool
}

/// Disk-backed candidate and digest metadata. Never opens source files or hashes
/// their contents: the caller remains responsible for bounded content reads.
public final class ScanCandidateIndex: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let database: ScanSQLiteConnection
    private var disposed = false
    var temporaryReference: ScanResultReference { database.location.reference }
    public static func createTemporary() throws -> ScanCandidateIndex {
        let location = try ScanOwnedLocation.create(.candidates)
        do { return try ScanCandidateIndex(database: ScanSQLiteConnection(location: location, readOnly: false, creating: true)) }
        catch { try? location.removeArtifacts(); throw error }
    }
    private init(database: ScanSQLiteConnection) throws {
        self.database = database
        try database.execute("""
        CREATE TABLE candidates(path TEXT PRIMARY KEY,root_path TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),identity_json BLOB NOT NULL,digest TEXT,UNIQUE(device,inode));
        CREATE INDEX candidate_sizes ON candidates(bytes,path);
        CREATE INDEX candidate_digests ON candidates(digest,bytes,path) WHERE digest IS NOT NULL;
        """)
    }
    deinit { try? dispose() }
    private func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 32768 else { throw ScanStoreError.rejected("候选路径无效或过大。") }
        return ScanLexicalPath.normalize(path)
    }
    public func append(path: String, rootPath: String, identity: FileIdentity, bytes: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try database.requireWritable()
        let path = try normalized(path), root = try normalized(rootPath)
        guard FileSafety.contains(root, path), bytes >= 0, identity.size == bytes, identity.modified.isFinite else { throw ScanStoreError.rejected("候选范围、大小或身份不一致。") }
        let payload = try JSONEncoder().encode(identity)
        try database.beginWrite()
        let statement = try database.prepare("INSERT OR IGNORE INTO candidates(path,root_path,device,inode,size,modified,bytes,identity_json) VALUES(?,?,?,?,?,?,?,?)")
        try statement.text(path, at: 1); try statement.text(root, at: 2)
        try statement.integer(Int64(bitPattern: identity.device), at: 3); try statement.integer(Int64(bitPattern: identity.inode), at: 4)
        try statement.integer(identity.size, at: 5); try statement.double(identity.modified, at: 6); try statement.integer(bytes, at: 7); try statement.blob(payload, at: 8)
        _ = try statement.step(); try database.didWrite()
    }
    public func flush() throws { lock.lock(); defer { lock.unlock() }; try database.flush() }
    public func forEachDuplicateSizeCandidate(shouldStop: () -> Bool = { false }, _ body: (ScanIndexedCandidate) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        try database.withCancellation(shouldStop) {
        let statement = try database.prepare("""
        SELECT c.path,c.root_path,c.identity_json,c.bytes FROM candidates c
        WHERE c.bytes IN (SELECT bytes FROM candidates GROUP BY bytes HAVING count(*)>1)
        ORDER BY c.bytes,c.path
        """)
        while try statement.step() {
            try autoreleasepool {
                let item = ScanIndexedCandidate(path: try statement.string(0), rootPath: try statement.string(1), identity: try JSONDecoder().decode(FileIdentity.self, from: statement.data(2)), bytes: statement.integer(3))
                try body(item)
            }
        }
        }
    }
    public func recordDigest(path: String, digest: String, identity: FileIdentity) throws {
        lock.lock(); defer { lock.unlock() }; try database.requireWritable()
        guard !digest.isEmpty, digest.utf8.count <= 256, !digest.utf8.contains(0), identity.modified.isFinite else { throw ScanStoreError.rejected("摘要内容无效。") }
        let path = try normalized(path)
        try database.beginWrite()
        let statement = try database.prepare("UPDATE candidates SET digest=? WHERE path=? AND device=? AND inode=? AND size=? AND modified=?")
        try statement.text(digest, at: 1); try statement.text(path, at: 2); try statement.integer(Int64(bitPattern: identity.device), at: 3); try statement.integer(Int64(bitPattern: identity.inode), at: 4); try statement.integer(identity.size, at: 5); try statement.double(identity.modified, at: 6)
        _ = try statement.step()
        guard sqlite3_changes(database.pointer) == 1 else { throw ScanStoreError.rejected("文件身份在摘要计算后变化，未记录摘要。") }
        try database.didWrite()
    }
    public func forEachDuplicateGroupItem(shouldStop: () -> Bool = { false }, _ body: (ScanDuplicateGroupItem) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        try database.withCancellation(shouldStop) {
        let statement = try database.prepare("""
        SELECT c.digest,c.path,c.root_path,c.bytes,c.identity_json,k.path,k.identity_json FROM candidates c
        JOIN (SELECT digest,bytes,min(path) AS keeper FROM candidates WHERE digest IS NOT NULL GROUP BY digest,bytes HAVING count(*)>1) digest_groups
          ON digest_groups.digest=c.digest AND digest_groups.bytes=c.bytes
        JOIN candidates k ON k.path=digest_groups.keeper
        ORDER BY c.digest,c.bytes,c.path
        """)
        while try statement.step() {
            try autoreleasepool {
                let path = try statement.string(1), keeper = try statement.string(5)
                let item = ScanDuplicateGroupItem(groupDigest: try statement.string(0), path: path, rootPath: try statement.string(2), bytes: statement.integer(3), identity: try JSONDecoder().decode(FileIdentity.self, from: statement.data(4)), keeperPath: keeper, keeperIdentity: try JSONDecoder().decode(FileIdentity.self, from: statement.data(6)), isKeeper: path == keeper)
                try body(item)
            }
        }
        }
    }
    public func dispose() throws {
        lock.lock(); defer { lock.unlock() }
        if disposed { return }
        try database.close()
        // The path is derived from our private creation capability, never from a
        // source candidate. Validate ownership again before removing artifacts.
        try database.location.removeArtifacts(); disposed = true
    }
}
