import Foundation
import Darwin
import CSQLite
@testable import CleanRoomCore

private enum ScanStoreFixtureError: Error { case stopped, SQL }
private func scanStoreFixtureSQL(_ path: String, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { sqlite3_close(db); throw ScanStoreFixtureError.SQL }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ScanStoreFixtureError.SQL }
}
func runScanStoreChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/scan-store-" + UUID().uuidString)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let generatedSource = fixture.appendingPathComponent("generated-source.txt")
    try Data("source must remain unchanged".utf8).write(to: generatedSource)
    var references: [ScanResultReference] = []
    defer { for reference in references { try? ScanResultStore.remove(reference) } }
    let store = try ScanResultStore.createTemporary(); references.append(store.reference)
    for index in 0...10_000 {
        try autoreleasepool {
            let path = fixture.appendingPathComponent(String(format: "source-%05d", index)).path
            try store.append(ScanItem(path: path, category: "generated", bytes: Int64(index), detail: index % 97 == 0 ? "needle" : "ordinary", canTrash: index % 2 == 0))
        }
    }
    try store.append(ScanItem(path: fixture.appendingPathComponent("source-00123").path, category: "generated", bytes: 123, detail: "ignored duplicate"))
    try store.flush()
    let stats = try store.statistics()
    checkEqual(stats.totalCount, 10_001); checkEqual(stats.processableCount, 5001)
    checkEqual(stats.totalBytes, 50_005_000); checkEqual(stats.processableBytes, 25_005_000); checkEqual(stats.maximumBytes, 10_000)
    var scanned = 0
    for offset in stride(from: 0, through: 10_000, by: 200) {
        let page = try store.page(offset: offset, limit: 200, largestFirst: false)
        checkEqual(page.filteredCount, 10_001); checkTrue(page.items.count <= 200)
        for item in page.items {
            checkEqual(item.path, fixture.appendingPathComponent(String(format: "source-%05d", scanned)).path)
            scanned += 1
        }
    }
    checkEqual(scanned, 10_001)
    let descending = try store.page(limit: 1000)
    checkEqual(descending.items.count, 200); checkEqual(descending.items.first?.bytes, 10_000); checkEqual(descending.items.last?.bytes, 9801)
    checkEqual(try store.page(limit: 0).items.isEmpty, true)
    let search = try store.page(query: "NEEDLE")
    checkEqual(search.filteredCount, 104); checkEqual(search.items.count, 104)
    checkEqual(try store.page(query: "needle", processableOnly: true).filteredCount, 52)
    checkEqual(try store.page(query: "needle%").filteredCount, 0)
    checkEqual(try store.page(query: "' OR 1=1 --").filteredCount, 0)
    var streamCount = 0, streamBytes: Int64 = 0
    try store.forEachItem { item in streamCount += 1; streamBytes += item.bytes }
    checkEqual(streamCount, 10_001); checkEqual(streamBytes, stats.totalBytes)
    var partialCount = 0
    checkThrows(try store.forEachItem { _ in partialCount += 1; if partialCount == 7 { throw ScanStoreFixtureError.stopped } })
    checkEqual(partialCount, 7)
    var cancellationChecks = 0
    checkThrows(try store.page(query: "no matches anywhere", isCancelled: { cancellationChecks += 1; return cancellationChecks > 2 }))
    checkEqual(try store.statistics().totalCount, 10_001)
    let reader = try ScanResultStore(reference: store.reference)
    checkEqual(try reader.page(offset: 10_000, largestFirst: false).items.count, 1)
    checkThrows(try reader.append(ScanItem(path: generatedSource.path, category: "blocked")))
    checkThrows(try reader.appendIfNoOverlap(ScanItem(path: generatedSource.path, category: "blocked")))
    checkThrows(try reader.removeAncestors(of: generatedSource.path))
    var metadata = stat(); checkEqual(lstat(store.reference.path, &metadata), 0); checkEqual(metadata.st_mode & 0o777, 0o600)
    checkEqual(lstat(URL(fileURLWithPath: store.reference.path).deletingLastPathComponent().path, &metadata), 0); checkEqual(metadata.st_mode & 0o777, 0o700)
    let overlap = try ScanResultStore.createTemporary(); references.append(overlap.reference)
    let parent = fixture.appendingPathComponent("folder").path
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent + "/child", category: "first", bytes: 3, canTrash: true)), true)
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent, category: "ancestor", bytes: 9)), false)
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent + "/child/deep", category: "descendant")), false)
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent + "/child", category: "same path different ID")), false)
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent + "-sibling", category: "sibling", bytes: 5, canTrash: true)), true)
    try overlap.removeAncestors(of: parent + "/child/keeper")
    checkEqual(try overlap.statistics().totalCount, 1); checkEqual(try overlap.statistics().maximumBytes, 5)
    try overlap.removeAncestors(of: parent + "-sibling")
    checkEqual(try overlap.statistics().totalCount, 0); checkEqual(try overlap.statistics().maximumBytes, 0)
    checkEqual(try overlap.appendIfNoOverlap(ScanItem(path: parent, category: "keeper ancestor", bytes: 10, canTrash: true)), true)
    try overlap.removeAncestors(of: parent + "/keeper")
    checkEqual(try overlap.statistics().totalCount, 0)
    let bad = try ScanResultStore.createTemporary(); references.append(bad.reference); try bad.flush()
    try scanStoreFixtureSQL(bad.reference.path, "PRAGMA user_version=999")
    checkThrows(try ScanResultStore(reference: bad.reference)); checkThrows(try ScanResultStore.remove(bad.reference))
    checkTrue(fm.fileExists(atPath: bad.reference.path))
    try scanStoreFixtureSQL(bad.reference.path, "PRAGMA user_version=1")
    checkThrows(try ScanResultStore(reference: ScanResultReference(path: generatedSource.path, sessionID: bad.reference.sessionID)))
    checkThrows(try ScanResultStore(reference: ScanResultReference(path: bad.reference.path, sessionID: UUID().uuidString)))
    let ownerDirectory = URL(fileURLWithPath: bad.reference.path).deletingLastPathComponent()
    let foreign = ownerDirectory.appendingPathComponent("unexpected-generated-source")
    try Data("never remove unexpected files".utf8).write(to: foreign)
    checkThrows(try ScanResultStore.remove(bad.reference)); checkTrue(fm.fileExists(atPath: foreign.path)); checkTrue(fm.fileExists(atPath: bad.reference.path))
    try fm.removeItem(at: foreign)
    let sidecarLink = URL(fileURLWithPath: bad.reference.path + "-wal")
    try fm.createSymbolicLink(at: sidecarLink, withDestinationURL: generatedSource)
    checkThrows(try ScanResultStore(reference: bad.reference)); checkThrows(try ScanResultStore.remove(bad.reference))
    try fm.removeItem(at: sidecarLink)
    try fm.linkItem(at: generatedSource, to: sidecarLink)
    checkThrows(try ScanResultStore(reference: bad.reference)); checkThrows(try ScanResultStore.remove(bad.reference))
    try fm.removeItem(at: sidecarLink)
    let movedDB = fixture.appendingPathComponent("temporarily-moved-owned-db")
    try fm.moveItem(at: URL(fileURLWithPath: bad.reference.path), to: movedDB)
    try fm.createSymbolicLink(at: URL(fileURLWithPath: bad.reference.path), withDestinationURL: generatedSource)
    checkThrows(try ScanResultStore(reference: bad.reference)); checkThrows(try ScanResultStore.remove(bad.reference))
    try fm.removeItem(atPath: bad.reference.path); try fm.moveItem(at: movedDB, to: URL(fileURLWithPath: bad.reference.path))
    let movedDirectory = fixture.appendingPathComponent("temporarily-moved-owned-directory")
    try fm.moveItem(at: ownerDirectory, to: movedDirectory)
    try fm.createSymbolicLink(at: ownerDirectory, withDestinationURL: movedDirectory)
    checkThrows(try ScanResultStore(reference: bad.reference)); checkThrows(try ScanResultStore.remove(bad.reference))
    try fm.removeItem(at: ownerDirectory); try fm.moveItem(at: movedDirectory, to: ownerDirectory)
    let index = try ScanCandidateIndex.createTemporary()
    defer { try? index.dispose() }
    let indexPath = index.temporaryReference.path
    for number in 0...10_000 {
        let bytes: Int64 = number < 3000 ? 5 : (number < 6000 ? 7 : Int64(number))
        let identity = FileIdentity(device: 1, inode: UInt64(number + 1), size: bytes, modified: 1)
        try index.append(path: fixture.appendingPathComponent(String(format: "candidate-%05d", number)).path, rootPath: fixture.path, identity: identity, bytes: bytes)
    }
    try index.append(path: fixture.appendingPathComponent("hardlink-alias").path, rootPath: fixture.path, identity: FileIdentity(device: 1, inode: 1, size: 5, modified: 1), bytes: 5)
    var candidateCount = 0
    try index.forEachDuplicateSizeCandidate { candidate in
        candidateCount += 1
        let digest = candidate.bytes == 7 ? "digest-C" : (candidate.identity.inode % 2 == 0 ? "digest-A" : "digest-B")
        try index.recordDigest(path: candidate.path, digest: digest, identity: candidate.identity)
    }
    checkEqual(candidateCount, 6000)
    let changedIdentity = FileIdentity(device: 1, inode: 1, size: 5, modified: 2)
    checkThrows(try index.recordDigest(path: fixture.appendingPathComponent("candidate-00000").path, digest: "changed", identity: changedIdentity))
    var groupCount = 0, keeperCount = 0
    try index.forEachDuplicateGroupItem { item in
        groupCount += 1
        if item.isKeeper { keeperCount += 1; checkEqual(item.path, item.keeperPath) }
        checkTrue(item.keeperPath <= item.path)
        if item.groupDigest == "digest-A" { checkTrue(item.keeperPath.hasSuffix("candidate-00001")) }
        if item.groupDigest == "digest-B" { checkTrue(item.keeperPath.hasSuffix("candidate-00000")) }
        if item.groupDigest == "digest-C" { checkTrue(item.keeperPath.hasSuffix("candidate-03000")) }
    }
    checkEqual(groupCount, 6000); checkEqual(keeperCount, 3)
    checkThrows(try index.forEachDuplicateGroupItem { _ in throw ScanStoreFixtureError.stopped })
    try index.dispose(); checkFalse(fm.fileExists(atPath: indexPath))
    checkThrows(try index.append(path: generatedSource.path, rootPath: fixture.path, identity: FileIdentity(device: 1, inode: 1, size: 1, modified: 1), bytes: 1))
    for reference in references { try ScanResultStore.remove(reference); checkFalse(fm.fileExists(atPath: reference.path)) }
    checkEqual(try String(contentsOf: generatedSource, encoding: .utf8), "source must remain unchanged")
    print("PASS disk result paging 10001 rows, search/stats, overlaps, owned-store safety, streamed digest groups")
}
