import Foundation
import Darwin
@testable import CleanRoomCore

private final class ExtendedScaleStop: @unchecked Sendable {
    let cancellation = MalwareCancellation()
    func progress(_ count: Int) { if count >= 100 { cancellation.cancel() } }
}

func runExtendedScaleChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/extended-scale-" + UUID().uuidString)
    let home = fixture.appendingPathComponent("fake-home"), cache = home.appendingPathComponent(".npm/_cacache")
    let tree = cache.appendingPathComponent("zz-large"), trash = home.appendingPathComponent("generated-trash")
    for path in [home, cache, tree, trash] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: fixture) }
    var references: [ScanResultReference] = []
    defer { for reference in references { try? ScanResultStore.remove(reference) } }
    func keepCleanup(_ report: ExtendedCleanupReport) -> ExtendedCleanupReport { if let reference = report.resultStore { references.append(reference) }; return report }
    func keepTrash(_ report: TrashInspectionReport) -> TrashInspectionReport { if let reference = report.resultStore { references.append(reference) }; return report }
    func generatedFile(_ path: URL, size: Int64 = 64) throws {
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExtendedCleanupError.rejected("fixture file creation failed") }
        defer { close(fd) }
        guard ftruncate(fd, size) == 0 else { throw ExtendedCleanupError.rejected("fixture truncate failed") }
    }
    // 50,001 descendants exceeds the previous traversal limit even when it is a
    // single cache candidate. A further 2,001 top-level files exceed the old list.
    for index in 0..<50_001 { try autoreleasepool { try generatedFile(tree.appendingPathComponent("node-\(index)")) } }
    for index in 0..<2_001 { try autoreleasepool { try generatedFile(cache.appendingPathComponent(String(format: "entry-%05d", index))) } }
    let options = ExtendedCleanupOptions(home: home, maxFiles: 1, maxResults: 1, maxSeconds: 0.01)
    checkTrue(options.scanToCompletion)
    let scanner = ExtendedCleanupScanner()
    let report = keepCleanup(scanner.scan(.developerCaches, options: options))
    checkFalse(report.truncated); checkFalse(report.cancelled)
    checkTrue(report.visitedFiles > 50_000); checkEqual(report.totalCount, 2_002)
    checkEqual(report.items.count, 1); checkEqual(report.processableCount, 2_002)
    checkEqual(report.totalBytes, 52_002 * 64)
    let results = try ScanResultStore(reference: try unwrap(report.resultStore))
    let finalPage = try results.page(offset: 2_000, largestFirst: false)
    checkEqual(finalPage.items.count, 2); checkEqual(finalPage.filteredCount, 2_002)
    let largeCandidate = try unwrap(finalPage.items.first { $0.path == tree.path })
    checkTrue(largeCandidate.canTrash); checkEqual(largeCandidate.bytes, 50_001 * 64)
    var persisted = 0
    try results.forEachItem { _ in persisted += 1 }
    checkEqual(persisted, 2_002)
    let cancelled = ExtendedScaleStop()
    let partial = keepCleanup(scanner.scan(.developerCaches, options: options, cancellation: cancelled.cancellation,
                                    progress: { count, _ in cancelled.progress(count) }))
    checkTrue(partial.cancelled); checkTrue(partial.truncated); checkTrue(partial.visitedFiles < report.visitedFiles)

    // Keep the 4MB plist bound explicit and truthful, without allocating a large
    // payload or turning a parser budget into an unlimited content read.
    let preferences = home.appendingPathComponent("Library/Preferences")
    try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
    try generatedFile(preferences.appendingPathComponent("too-large.plist"), size: 4_000_001)
    let parsed = keepCleanup(scanner.scan(.brokenPreferences, options: options))
    checkTrue(parsed.truncated); checkEqual(parsed.totalCount, 0)
    checkTrue(parsed.warnings.contains { $0.contains("4MB") })

    // Move only our generated sources into a separately injected fake Trash.
    // No production Trash root is inspected or mutated by this check.
    try fm.moveItem(at: tree, to: trash.appendingPathComponent("zz-large"))
    for index in 0..<2_001 {
        let name = String(format: "entry-%05d", index)
        try fm.moveItem(at: cache.appendingPathComponent(name), to: trash.appendingPathComponent(name))
    }
    let inspector = TrashInspector(testRoots: [trash], home: home)
    let inventory = keepTrash(inspector.scan(options: options))
    checkFalse(inventory.truncated); checkFalse(inventory.cancelled)
    checkTrue(inventory.visitedFiles > 50_000); checkEqual(inventory.totalCount, 2_002)
    checkEqual(inventory.items.count, 1); checkEqual(inventory.processableCount, 2_002)
    let trashStore = try TrashInspectionStore(reference: try unwrap(inventory.resultStore))
    let trashLast = try trashStore.page(offset: 2_000)
    checkEqual(trashLast.items.count, 2); checkEqual(trashLast.filteredCount, 2_002)
    let large = try unwrap(trashLast.items.first { $0.path.hasSuffix("/zz-large") })
    checkTrue(large.canPermanentlyDelete); checkEqual(large.bytes, 50_001 * 64)
    var receiptCount = 0
    try trashStore.forEachItem { item in
        receiptCount += 1
        checkEqual(item.trashRoot, trash.path); checkTrue(item.canPermanentlyDelete)
    }
    checkEqual(receiptCount, 2_002)
    let trashStop = ExtendedScaleStop()
    let trashPartial = keepTrash(inspector.scan(options: options, cancellation: trashStop.cancellation,
                                           progress: { count, _ in trashStop.progress(count) }))
    checkTrue(trashPartial.cancelled); checkTrue(trashPartial.truncated)
    // Preflight + removal now visit >100k nodes. There is still one explicitly
    // confirmed top-level item; repeated counting must not abort at 50k.
    let deleted = inspector.permanentlyDelete([large], confirmed: true, confirmationPaths: [large.path])
    checkEqual(deleted.deletedPaths, [large.path]); checkTrue(deleted.errors.isEmpty); checkFalse(deleted.cancelled)
    checkFalse(fm.fileExists(atPath: large.path)); checkTrue(fm.fileExists(atPath: trash.path))
    checkTrue(fm.fileExists(atPath: trash.appendingPathComponent("entry-00000").path))
    print("PASS advanced full scan fixtures: >50k cache descendants, >2k disk candidates/trash receipts, preview1/final page/cancel, generated-tree permanent deletion without double-count limit")
}
