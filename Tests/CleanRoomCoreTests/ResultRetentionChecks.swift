import Foundation
import CSQLite
import CleanRoomCore

private enum ResultRetentionFixtureError: Error { case sql }
private func retentionFixtureSQL(_ reference: ScanResultReference, _ sql: String) throws {
    // Only callers' freshly created, schema-owned fixture stores are passed.
    var pointer: OpaquePointer?
    guard sqlite3_open_v2(reference.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let pointer else {
        sqlite3_close(pointer); throw ResultRetentionFixtureError.sql
    }
    defer { sqlite3_close(pointer) }
    guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw ResultRetentionFixtureError.sql }
}

func runResultRetentionChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/result-retention-" + UUID().uuidString)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    var references: [ScanResultReference] = []
    defer { for reference in references { try? ScanResultStore.remove(reference) }; try? fm.removeItem(at: fixture) }
    let root = fixture.path + "/metadata"
    func path(_ index: Int) -> String { root + String(format: "/item-%04d", index) }
    func generatedItem(_ index: Int) -> ScanItem {
        let bytes = Int64(index + 1)
        return ScanItem(path: path(index), name: "fixture-\(index)", category: "保留候选-\(index % 3)", bytes: bytes,
                        detail: "生成的元数据 \(index) · 引号\"与换行\n仍保留", group: "group-\(index % 4)", canTrash: index % 2 == 0,
                        identity: FileIdentity(device: 41, inode: UInt64(index + 100), size: bytes, modified: 1_700_000_000 + Double(index) / 8),
                        scopeRoot: root, retainedPath: fixture.path + "/keepers/original-\(index % 4)",
                        retainedIdentity: FileIdentity(device: 41, inode: UInt64(9000 + index % 4), size: 64, modified: 1_700_000_000))
    }
    func assertStatistics(_ statistics: ScanResultStatistics, removing removed: Set<Int>) {
        var count = 0, processable = 0
        var bytes: Int64 = 0, processableBytes: Int64 = 0, maximum: Int64 = 0
        for index in 0..<1001 where !removed.contains(index) {
            let size = Int64(index + 1)
            count += 1; bytes += size; maximum = max(maximum, size)
            if index % 2 == 0 { processable += 1; processableBytes += size }
        }
        checkEqual(statistics.totalCount, count); checkEqual(statistics.processableCount, processable)
        checkEqual(statistics.totalBytes, bytes); checkEqual(statistics.processableBytes, processableBytes)
        checkEqual(statistics.maximumBytes, maximum)
    }
    // This one generated source proves metadata pruning never touches files.
    try fm.createDirectory(at: URL(fileURLWithPath: root), withIntermediateDirectories: true)
    let witness = URL(fileURLWithPath: path(0)), witnessData = Data("fixture-source-must-survive".utf8)
    try witnessData.write(to: witness)
    let store = try ScanResultStore.createTemporary(); references.append(store.reference)
    for index in 0..<1001 { try autoreleasepool { try store.append(generatedItem(index)) } }
    try store.flush()
    let reference = store.reference
    assertStatistics(try store.statistics(), removing: [])
    checkEqual(try store.page(offset: 1000).items.count, 1)
    let removed: Set<Int> = [0, 200, 400, 600, 800, 1000]
    let pruned = try store.removeProcessedPaths(removed.sorted().map(path))
    checkEqual(store.reference, reference)
    assertStatistics(pruned, removing: removed)
    assertStatistics(try store.statistics(), removing: removed)
    checkEqual(try Data(contentsOf: witness), witnessData)
    checkEqual(try store.page(offset: 1000).items.count, 0) // UI must clamp its obsolete tail page.
    checkEqual(try store.page(offset: 800, largestFirst: false).items.count, 195)
    let repeated = try store.removeProcessedPaths([path(0), path(0), path(1000), root + "/not-present"])
    assertStatistics(repeated, removing: removed)
    assertStatistics(try store.removeProcessedPaths([]), removing: removed)

    // Every path is prevalidated before any deletion, including normalized /.
    for invalid in ["", "relative/file", "../outside", "/bad\u{0}path", "/", "/./", "/generated/.."] {
        checkThrows(try store.removeProcessedPaths([path(100), invalid]))
        assertStatistics(try store.statistics(), removing: removed)
    }
    let reader = try ScanResultStore(reference: reference)
    checkThrows(try reader.removeProcessedPaths([path(100)]))
    assertStatistics(try reader.statistics(), removing: removed)

    // A later SQL failure must roll back earlier rows and all trigger statistics.
    let blocked = path(102).replacingOccurrences(of: "'", with: "''")
    try retentionFixtureSQL(reference, "CREATE TRIGGER retention_fixture_abort BEFORE DELETE ON scan_items WHEN OLD.path='\(blocked)' BEGIN SELECT RAISE(ABORT,'retention fixture rollback'); END;")
    checkThrows(try store.removeProcessedPaths([path(101), path(102)]))
    assertStatistics(try store.statistics(), removing: removed)
    try retentionFixtureSQL(reference, "DROP TRIGGER retention_fixture_abort;")

    // Prune through a reopened writer and read it back using the same reference.
    let reopened = try ScanResultStore(reference: reference, readOnly: false)
    let finalRemoved = removed.union([998, 999])
    assertStatistics(try reopened.removeProcessedPaths([path(998), path(999)]), removing: finalRemoved)
    checkEqual(reopened.reference, reference)
    let fresh = try ScanResultStore(reference: reference)
    assertStatistics(try fresh.statistics(), removing: finalRemoved)
    var nextExpected = 0, observed = 0
    for offset in stride(from: 0, to: 1001 - finalRemoved.count, by: 200) {
        let page = try fresh.page(offset: offset, largestFirst: false)
        checkTrue(page.items.count <= 200); checkEqual(page.filteredCount, 1001 - finalRemoved.count)
        for item in page.items {
            while finalRemoved.contains(nextExpected) { nextExpected += 1 }
            checkEqual(item, generatedItem(nextExpected)); nextExpected += 1; observed += 1
        }
    }
    checkEqual(observed, 1001 - finalRemoved.count)

    // Export must include every remaining row, even with a stale preview/count.
    var report = ScanReport(kind: .cleanup, items: try fresh.page().items)
    report.resultStore = reference; report.totalItemCount = 1001; report.processableItemCount = 501; report.allItemsBytes = -1
    let exported = fixture.appendingPathComponent("remaining-results.json")
    try ScanReportExporter.write(report, to: exported)
    let input = try FileHandle(forReadingFrom: exported); defer { try? input.close() }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    var buffer = Data(), lineNumber = 0, exportedCount = 0, exportExpected = 0
    var footer = false
    func consume(_ line: Data) throws {
        try autoreleasepool {
            lineNumber += 1
            if lineNumber == 1 {
                let suffix = Data(",\"items\":[".utf8)
                checkTrue(line.suffix(suffix.count) == suffix)
                var header = Data(line.dropLast(suffix.count)); header.append(0x7D)
                let metadata = try JSONSerialization.jsonObject(with: header) as? [String: Any]
                let statistics = try fresh.statistics()
                checkEqual((metadata?["totalItemCount"] as? NSNumber)?.intValue, statistics.totalCount)
                checkEqual((metadata?["processableItemCount"] as? NSNumber)?.intValue, statistics.processableCount)
                checkEqual((metadata?["allItemsBytes"] as? NSNumber)?.int64Value, statistics.totalBytes)
                checkTrue(metadata?["resultStore"] == nil)
            } else if line == Data("]}".utf8) { footer = true }
            else {
                var payload = line; if payload.last == 0x2C { payload.removeLast() }
                let item = try decoder.decode(ScanItem.self, from: payload)
                while finalRemoved.contains(exportExpected) { exportExpected += 1 }
                checkEqual(item, generatedItem(exportExpected)); exportExpected += 1; exportedCount += 1
            }
        }
    }
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline); try consume(line)
        }
        checkLessThan(buffer.count, 64 * 1024)
    }
    checkTrue(buffer.isEmpty); checkTrue(footer)
    checkEqual(exportedCount, 1001 - finalRemoved.count)

    // Exact path/component semantics, without touching these conceptual paths.
    let boundary = try ScanResultStore.createTemporary(); references.append(boundary.reference)
    let base = fixture.path + "/boundary"
    func row(_ suffix: String, _ category: String, _ bytes: Int64) throws {
        try boundary.append(ScanItem(path: base + suffix, category: category, bytes: bytes, canTrash: true))
    }
    try row("/keep-parent", "parent-not-selected", 1); try row("/keep-parent/child", "selected-child", 2)
    try row("/done-parent", "selected-parent", 3); try row("/done-parent/child", "child", 4); try row("/done-parent/deep/leaf", "leaf", 5)
    try row("/done-parent-sibling/child", "prefix-sibling", 6); try row("/done-parent2", "prefix-sibling-two", 7)
    try row("/twin", "same-path-first-id", 8); try row("/twin", "same-path-second-id", 9)
    try row("/资料😀", "unicode-parent", 10); try row("/资料😀/缓存", "unicode-child", 11); try row("/资料😀号/缓存", "unicode-prefix-sibling", 12)
    let nfd = base + "/e\u{301}", nfc = base + "/é"
    checkFalse(nfd.utf8.elementsEqual(nfc.utf8))
    try boundary.append(ScanItem(path: nfd + "/value", category: "NFD child", bytes: 13, canTrash: true))
    try boundary.append(ScanItem(path: nfc + "/value", category: "NFC child", bytes: 14, canTrash: true))
    let nonce = UUID().uuidString
    let privatePath = "/private/var/AIYOUClean-retention-" + nonce + "/same"
    let varPath = "/var/AIYOUClean-retention-" + nonce + "/same"
    try boundary.append(ScanItem(path: privatePath, category: "literal-private", bytes: 15, canTrash: true))
    try boundary.append(ScanItem(path: varPath, category: "literal-var", bytes: 16, canTrash: true))
    try boundary.flush()
    func has(_ expected: String) throws -> Bool {
        var found = false
        try boundary.forEachItem { if $0.path.utf8.elementsEqual(expected.utf8) { found = true } }
        return found
    }
    _ = try boundary.removeProcessedPaths([base + "/keep-parent/child"])
    checkEqual(try has(base + "/keep-parent"), true); checkEqual(try has(base + "/keep-parent/child"), false)
    _ = try boundary.removeProcessedPaths([base + "/done-parent"])
    checkEqual(try has(base + "/done-parent"), false); checkEqual(try has(base + "/done-parent/deep/leaf"), false)
    checkEqual(try has(base + "/done-parent-sibling/child"), true); checkEqual(try has(base + "/done-parent2"), true)
    _ = try boundary.removeProcessedPaths([base + "/twin"])
    checkEqual(try has(base + "/twin"), false)
    _ = try boundary.removeProcessedPaths([base + "/资料😀"])
    checkEqual(try has(base + "/资料😀/缓存"), false); checkEqual(try has(base + "/资料😀号/缓存"), true)
    _ = try boundary.removeProcessedPaths([nfd, nfc])
    checkEqual(try has(nfd + "/value"), false); checkEqual(try has(nfc + "/value"), false)
    let last = try boundary.removeProcessedPaths([privatePath])
    checkEqual(try has(privatePath), false); checkEqual(try has(varPath), true)
    checkEqual(last.totalCount, 5); checkEqual(last.totalBytes, 42); checkEqual(last.maximumBytes, 16)
    print("PASS partial result retention: stable ref, 1001 rows, atomic prune, metadata/export and lexical path boundaries")
}
