import Foundation
import Darwin
import CleanRoomCore

private final class ExportCheckControl: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let cancelAfter: Int?
    let createOnCall: Int?
    let destination: URL?
    init(cancelAfter: Int? = nil, createOnCall: Int? = nil, destination: URL? = nil) {
        self.cancelAfter = cancelAfter; self.createOnCall = createOnCall; self.destination = destination
    }
    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if calls == createOnCall, let destination {
            // Simulates an unrelated writer creating the final path during export.
            _ = FileManager.default.createFile(atPath: destination.path, contents: Data("keep-racing-writer".utf8))
        }
        return cancelAfter.map { calls > $0 } ?? false
    }
}

func runExportChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/export-" + UUID().uuidString)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let store = try ScanResultStore.createTemporary()
    defer { try? ScanResultStore.remove(store.reference) }
    var expectedBytes: Int64 = 0
    for index in 0..<10_001 {
        let bytes = Int64(index % 31 + 1); expectedBytes += bytes
        try autoreleasepool {
            let item = ScanItem(path: fixture.appendingPathComponent("generated-item-\(index)-引号\".cache").path,
                                category: "夹具\n分类", bytes: bytes, detail: "仅模拟元数据，未读取用户文件", canTrash: index % 2 == 0)
            try store.append(item)
        }
    }
    try store.flush()
    let page = try store.page()
    checkEqual(page.items.count, 200)
    var report = ScanReport(kind: .cleanup, items: page.items, visitedFiles: 10_001)
    report.resultStore = store.reference
    report.totalItemCount = 10_001; report.processableItemCount = 5_001; report.allItemsBytes = expectedBytes
    let output = fixture.appendingPathComponent("all-results.json")
    try ScanReportExporter.write(report, to: output)

    // Verify the exported JSON incrementally too: do not turn the 10,001-item
    // acceptance check into a whole-file Data/array allocation.
    let handle = try FileHandle(forReadingFrom: output)
    defer { try? handle.close() }
    var buffer = Data(), lineCount = 0, itemCount = 0, observedBytes: Int64 = 0, processable = 0
    var lastPath = "", sawFooter = false
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    func consume(_ line: Data) throws {
        try autoreleasepool {
            lineCount += 1
            if lineCount == 1 {
                let suffix = Data(",\"items\":[".utf8)
                checkTrue(line.suffix(suffix.count) == suffix)
                var metadata = Data(line.dropLast(suffix.count)); metadata.append(0x7D)
                let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
                checkEqual((object?["totalItemCount"] as? NSNumber)?.intValue, 10_001)
                checkEqual((object?["processableItemCount"] as? NSNumber)?.intValue, 5_001)
                checkEqual((object?["allItemsBytes"] as? NSNumber)?.int64Value, expectedBytes)
                checkTrue(object?["resultStore"] == nil)
            } else if line == Data("]}".utf8) { sawFooter = true }
            else {
                var payload = line
                if payload.last == 0x2C { payload.removeLast() }
                let item = try decoder.decode(ScanItem.self, from: payload)
                itemCount += 1; observedBytes += item.bytes; lastPath = item.path
                if item.canTrash { processable += 1 }
                checkEqual(item.category, "夹具\n分类")
            }
        }
    }
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            try consume(line)
        }
        checkLessThan(buffer.count, 64 * 1024)
    }
    checkTrue(buffer.isEmpty); checkTrue(sawFooter)
    checkEqual(itemCount, 10_001); checkEqual(processable, 5_001); checkEqual(observedBytes, expectedBytes)
    checkTrue(lastPath.contains("generated-item-10000-"))
    checkEqual((try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    func checkNoPartialFiles() throws {
        let names = try fm.contentsOfDirectory(atPath: fixture.path)
        checkFalse(names.contains { $0.hasPrefix(".AIYOUClean-export-") })
    }
    // Existing file and symlink targets remain untouched.
    let sentinel = fixture.appendingPathComponent("sentinel.json")
    try Data("existing-content".utf8).write(to: sentinel)
    checkThrows(try ScanReportExporter.write(report, to: sentinel))
    let sentinelHandle = try FileHandle(forReadingFrom: sentinel)
    checkEqual(String(decoding: try sentinelHandle.read(upToCount: 100) ?? Data(), as: UTF8.self), "existing-content")
    try sentinelHandle.close()
    let link = fixture.appendingPathComponent("link.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: sentinel)
    checkThrows(try ScanReportExporter.write(report, to: link))
    checkTrue(FileSafety.isSymbolicLink(link))
    try checkNoPartialFiles()

    // Cancellation after output starts leaves no final/partial file.
    let cancelled = fixture.appendingPathComponent("cancelled.json"), control = ExportCheckControl(cancelAfter: 100)
    checkThrows(try ScanReportExporter.write(report, to: cancelled, isCancelled: { control.check() }))
    checkFalse(fm.fileExists(atPath: cancelled.path)); try checkNoPartialFiles()

    // RENAME_EXCL must reject a path created after the initial existence check.
    let racing = fixture.appendingPathComponent("raced.json")
    let race = ExportCheckControl(createOnCall: 50, destination: racing)
    checkThrows(try ScanReportExporter.write(report, to: racing, isCancelled: { race.check() }))
    let racingHandle = try FileHandle(forReadingFrom: racing)
    checkEqual(String(decoding: try racingHandle.read(upToCount: 100) ?? Data(), as: UTF8.self), "keep-racing-writer")
    try racingHandle.close(); try checkNoPartialFiles()

    // A stale/forged store is not replaced with a preview-only successful export.
    var invalid = report
    invalid.resultStore = ScanResultReference(path: store.reference.path, sessionID: UUID().uuidString)
    let invalidOutput = fixture.appendingPathComponent("invalid-store.json")
    checkThrows(try ScanReportExporter.write(invalid, to: invalidOutput))
    checkFalse(fm.fileExists(atPath: invalidOutput.path)); try checkNoPartialFiles()

    let lease = try unwrap(WorkBudget.tryAcquire("export check busy"))
    checkThrows(try ScanReportExporter.write(report, to: fixture.appendingPathComponent("busy.json")))
    lease.release()
    let legacy = ScanReport(kind: .cleanup, items: [ScanItem(path: "/generated-only/one", category: "legacy", bytes: 7)])
    let legacyOutput = fixture.appendingPathComponent("legacy.json")
    try ScanReportExporter.write(legacy, to: legacyOutput)
    checkTrue(fm.fileExists(atPath: legacyOutput.path)); try checkNoPartialFiles()
}
