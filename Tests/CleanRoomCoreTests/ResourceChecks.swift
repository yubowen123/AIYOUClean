import Foundation
import CleanRoomCore

func runResourceChecks() throws {
    let first = try unwrap(WorkBudget.tryAcquire("fixture operation"))
    checkTrue(WorkBudget.tryAcquire("must be rejected") == nil)
    let rejected = Scanner().scan(.largeFiles)
    checkTrue(rejected.truncated); checkTrue(rejected.items.isEmpty)
    first.release()
    let second = try unwrap(WorkBudget.tryAcquire("new operation"))
    first.release() // Old tokens must not release a newer owner's operation.
    checkTrue(WorkBudget.tryAcquire("still rejected") == nil)
    second.release()
    checkTrue(ProcessResources.residentBytes().map { $0 > 0 } ?? false)
    let suite = CoreTests(); try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
    for i in 0..<20 { try suite.write("\(i)") }
    let options = ScanOptions(home: suite.home, roots: [suite.files], maxResults: 3)
    let report = Scanner().scan(.downloads, options: options)
    checkFalse(report.truncated); checkEqual(report.items.count, 3)
    checkEqual(report.totalItemCount, 20)
    checkEqual(report.resultLimit, 3); checkTrue(report.stopReason == nil)
    if let reference = report.resultStore { try? ScanResultStore.remove(reference) }
    let start = Date()
    let cancelled = Scanner().scan(.duplicates, options: options, isCancelled: { true })
    checkTrue(cancelled.truncated); checkLessThan(Date().timeIntervalSince(start), 0.5)
    let quote = ShellEscaping.command("/bin/example", ["$(touch bad)", "x'y", "a\nb"])
    checkTrue(quote.contains("'$(touch bad)'")); checkTrue(quote.contains("'x'\\''y'"))
    let m = TrashManager(storageURL: suite.root.appendingPathComponent("history-state/store.sqlite3"), home: suite.home, testTrash: suite.root.appendingPathComponent("history-trash"))
    var items: [ScanItem] = []
    for i in 0..<201 {
        let u = try suite.write("history-\(i)")
        items.append(ScanItem(path: u.path, category: "fixture", canTrash: true, identity: FileSafety.identity(u), scopeRoot: suite.files.path))
    }
    let moved = m.trash(items)
    checkTrue(moved.errors.isEmpty); checkEqual(moved.records.count, 201)
    checkEqual(m.records().count, 200); checkEqual(m.records(limit: 3).count, 3)
    let oldest = try unwrap(moved.records.first)
    try m.restore(oldest) // Lookup remains possible even if outside the latest UI page.
    checkTrue(FileManager.default.fileExists(atPath: oldest.originalPath))
    let refused = MaintenanceService.execute(.flushDNS, confirmed: false)
    checkFalse(refused.success); checkEqual(refused.note, "未执行")
}
