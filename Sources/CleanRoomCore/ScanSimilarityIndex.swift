import Foundation
import CSQLite

public struct ScanSimilarCandidate: Sendable {
    public let path: String
    public let rootPath: String
    public let bytes: Int64
    public let identity: FileIdentity
    public let hash: UInt64
    public init(path: String, rootPath: String, bytes: Int64, identity: FileIdentity, hash: UInt64) {
        self.path = path; self.rootPath = rootPath; self.bytes = bytes; self.identity = identity; self.hash = hash
    }
}

/// Disk-backed exact radius<=5 dHash grouping. The six segment lists are merged
/// by indexed keyset queries, never a capped candidate set or an in-memory group.
public final class ScanSimilarityIndex: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let database: ScanSQLiteConnection
    private var disposed = false
    var temporaryReference: ScanResultReference { database.location.reference }
    private static let fields = "path,root_path,bytes,identity_json,hash"
    private static let segmentShifts = [0, 11, 22, 33, 44, 54]
    private static let candidateSQL: String = {
        let branches = (0..<6).map { "SELECT (SELECT path FROM similar_candidates INDEXED BY similar_s\($0) WHERE assigned=0 AND s\($0)=? AND path>? ORDER BY path LIMIT 1) AS candidate_path" }.joined(separator: " UNION ALL ")
        return "SELECT " + ScanSimilarityIndex.fields + " FROM similar_candidates WHERE path=(SELECT min(candidate_path) FROM (" + branches + "))"
    }()
    public static func createTemporary() throws -> ScanSimilarityIndex {
        let location = try ScanOwnedLocation.create(.candidates)
        do { return try ScanSimilarityIndex(database: ScanSQLiteConnection(location: location, readOnly: false, creating: true)) }
        catch { try? location.removeArtifacts(); throw error }
    }
    private init(database: ScanSQLiteConnection) throws {
        self.database = database
        try database.execute("""
        INSERT INTO scan_meta(key,value) VALUES('index_type','dhash64-six-segments-v1');
        CREATE TABLE similar_candidates(path TEXT PRIMARY KEY,root_path TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),identity_json BLOB NOT NULL,hash INTEGER NOT NULL,s0 INTEGER NOT NULL,s1 INTEGER NOT NULL,s2 INTEGER NOT NULL,s3 INTEGER NOT NULL,s4 INTEGER NOT NULL,s5 INTEGER NOT NULL,assigned INTEGER NOT NULL DEFAULT 0 CHECK(assigned IN(0,1)));
        CREATE INDEX similar_unassigned ON similar_candidates(assigned,path);
        CREATE INDEX similar_s0 ON similar_candidates(assigned,s0,path);
        CREATE INDEX similar_s1 ON similar_candidates(assigned,s1,path);
        CREATE INDEX similar_s2 ON similar_candidates(assigned,s2,path);
        CREATE INDEX similar_s3 ON similar_candidates(assigned,s3,path);
        CREATE INDEX similar_s4 ON similar_candidates(assigned,s4,path);
        CREATE INDEX similar_s5 ON similar_candidates(assigned,s5,path);
        """)
    }
    deinit { try? dispose() }
    private static func segments(_ hash: UInt64) -> [Int64] {
        segmentShifts.enumerated().map { index, shift in Int64((hash >> shift) & (index < 4 ? 0x7ff : 0x3ff)) }
    }
    public func append(_ candidate: ScanSimilarCandidate) throws {
        lock.lock(); defer { lock.unlock() }; try database.requireWritable()
        guard candidate.path.hasPrefix("/"), candidate.rootPath.hasPrefix("/"), !candidate.path.utf8.contains(0), !candidate.rootPath.utf8.contains(0), candidate.path.utf8.count <= 32768, candidate.rootPath.utf8.count <= 32768,
              candidate.bytes >= 0, candidate.bytes == candidate.identity.size, candidate.identity.modified.isFinite else { throw ScanStoreError.rejected("相似图候选路径、大小或身份无效。") }
        let path = ScanLexicalPath.normalize(candidate.path), root = ScanLexicalPath.normalize(candidate.rootPath)
        guard FileSafety.contains(root, path) else { throw ScanStoreError.rejected("相似图候选超出指定根目录。") }
        try database.beginWrite()
        let statement = try database.prepare("INSERT OR IGNORE INTO similar_candidates(path,root_path,bytes,identity_json,hash,s0,s1,s2,s3,s4,s5) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
        try statement.text(path, at: 1); try statement.text(root, at: 2); try statement.integer(candidate.bytes, at: 3)
        try statement.blob(JSONEncoder().encode(candidate.identity), at: 4); try statement.integer(Int64(bitPattern: candidate.hash), at: 5)
        for (position, value) in Self.segments(candidate.hash).enumerated() { try statement.integer(value, at: Int32(position + 6)) }
        _ = try statement.step(); try database.didWrite()
    }
    public func flush() throws { lock.lock(); defer { lock.unlock() }; try database.flush() }
    /// Greedy groups use the first unassigned path in binary lexical order as a
    /// fixed reference. The reference is emitted only once a real match exists.
    /// shouldStop covers every candidate and SQLite query execution. False means
    /// cancelled/partial, never a successful complete grouping claim.
    public func forEachGroupItem(maxDistance: Int = 5, shouldStop: () -> Bool, _ body: (_ reference: ScanSimilarCandidate, _ item: ScanSimilarCandidate, _ isReference: Bool) throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; try database.flush()
        guard (0...5).contains(maxDistance) else { throw ScanStoreError.rejected("六段索引支持0到5位汉明距离，未按不完整候选范围处理。") }
        do {
            let complete = try database.withCancellation(shouldStop) {
                // Repeated calls regroup from scratch. Reset no more than 200
                // assignments per transaction, without decoding any candidate.
                while true {
                    if shouldStop() { return false }
                    if try !hasAssignedRows() { break }
                    try database.beginWrite()
                    let reset = try database.prepare("UPDATE similar_candidates SET assigned=0 WHERE path IN (SELECT path FROM similar_candidates WHERE assigned=1 ORDER BY path LIMIT 200)")
                    _ = try reset.step(); try database.didWrite(); try database.flush()
                }
                var lastReference = ""
                while true {
                    if shouldStop() { return false }
                    guard let reference = try nextReference(after: lastReference) else { return true }
                    lastReference = reference.path
                    try markAssigned(reference.path)
                    var lastCandidate = reference.path, emittedReference = false
                    while true {
                        if shouldStop() { return false }
                        guard let candidate = try nextCandidate(reference: reference, after: lastCandidate) else { break }
                        lastCandidate = candidate.path
                        // The six indexed lists have no global limit. Every row
                        // sharing any segment is eventually evaluated exactly once.
                        if (reference.hash ^ candidate.hash).nonzeroBitCount > maxDistance { continue }
                        if shouldStop() { return false }
                        try markAssigned(candidate.path)
                        if !emittedReference { try autoreleasepool { try body(reference, reference, true) }; emittedReference = true }
                        try autoreleasepool { try body(reference, candidate, false) }
                    }
                }
            }
            try database.flush(); return complete
        } catch ScanStoreError.cancelled {
            database.rollback(); return false
        }
    }
    private func decode(_ statement: ScanSQLiteStatement) throws -> ScanSimilarCandidate {
        ScanSimilarCandidate(path: try statement.string(0), rootPath: try statement.string(1), bytes: statement.integer(2), identity: try JSONDecoder().decode(FileIdentity.self, from: statement.data(3)), hash: UInt64(bitPattern: statement.integer(4)))
    }
    private func nextReference(after path: String) throws -> ScanSimilarCandidate? {
        try autoreleasepool {
            let statement = try database.prepare("SELECT " + Self.fields + " FROM similar_candidates WHERE assigned=0 AND path>? ORDER BY path LIMIT 1")
            try statement.text(path, at: 1)
            if try statement.step() { return try decode(statement) }
            return nil
        }
    }
    private func nextCandidate(reference: ScanSimilarCandidate, after path: String) throws -> ScanSimilarCandidate? {
        // Each segment subquery returns its next indexed key; min() is the
        // six-way union head. LIMIT 1 is keyset pagination, not a candidate cap.
        // The statement is finalized before assigned is mutated, so stale
        // materialized cursors cannot emit assigned rows or skip remaining keys.
        try autoreleasepool {
            let statement = try database.prepare(Self.candidateSQL)
            for (position, segment) in Self.segments(reference.hash).enumerated() {
                try statement.integer(segment, at: Int32(position * 2 + 1)); try statement.text(path, at: Int32(position * 2 + 2))
            }
            if try statement.step() { return try decode(statement) }
            return nil
        }
    }
    private func hasAssignedRows() throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM similar_candidates WHERE assigned=1 LIMIT 1")
        return try statement.step()
    }
    private func markAssigned(_ path: String) throws {
        try database.beginWrite()
        let statement = try database.prepare("UPDATE similar_candidates SET assigned=1 WHERE path=? AND assigned=0")
        try statement.text(path, at: 1); _ = try statement.step(); try database.didWrite()
    }
    public func dispose() throws {
        lock.lock(); defer { lock.unlock() }
        if disposed { return }
        try database.close(); try database.location.removeArtifacts(); disposed = true
    }
}
