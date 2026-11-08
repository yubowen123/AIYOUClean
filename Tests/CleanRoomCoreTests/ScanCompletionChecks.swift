import Foundation
import CleanRoomCore

func runScanCompletionChecks() throws {
    let s = CoreTests(); try s.setUpWithError(); defer { try? s.tearDownWithError() }
    let nested = s.files.appendingPathComponent("nested")
    for i in 0..<20 { try s.write("file-\(i)", Data(repeating: 1, count: 7), under: nested) }
    let limited = Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: 3, maxSeconds: 120, scanToCompletion: false))
    checkEqual(limited.stopReason, .fileLimit); checkEqual(limited.fileLimit, 3)
    checkTrue(limited.truncated); checkTrue(limited.warnings.contains { $0.contains("3 项") })
    checkTrue(limited.items.allSatisfy { !$0.canTrash })
    let timed = Scanner().scan(.downloads, options: .init(home: s.home, roots: [s.files], maxSeconds: 0, scanToCompletion: false))
    checkEqual(timed.stopReason, .timeLimit)
    let cancelled = Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files]), isCancelled: { true })
    checkEqual(cancelled.stopReason, .cancelled); checkTrue(cancelled.truncated)
    let full = Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: .max, maxSeconds: .infinity))
    checkFalse(full.truncated); checkTrue(full.stopReason == nil)
    checkTrue(full.fileLimit == nil); checkTrue(full.timeLimitSeconds == nil)
    checkEqual(full.totalBytes, 140)
    let fullItem = try unwrap(full.items.first); checkTrue(fullItem.canTrash)
    let flat = s.home.appendingPathComponent("flat")
    for i in 0..<6 { try s.write("file-\(i)", Data(repeating: 3, count: 5), under: flat) }
    let two = Scanner().scan(.downloads, options: .init(home: s.home, roots: [flat], maxFiles: 2, scanToCompletion: false))
    checkEqual(two.items.count, 2); checkEqual(two.totalBytes, 10)
    let boundedResults = Scanner().scan(.downloads, options: .init(home: s.home, roots: [flat], maxFiles: .max, maxSeconds: .infinity, maxResults: 2))
    checkFalse(boundedResults.truncated); checkTrue(boundedResults.stopReason == nil); checkEqual(boundedResults.items.count, 2)
    checkEqual(boundedResults.totalItemCount, 6)
    // Explicit bounded diagnostics retain their memory backstop; full scans spill.
    let retainedAllocation = Data(repeating: 0x7a, count: 64 * 1024 * 1024)
    let memoryStopped = withExtendedLifetime(retainedAllocation) {
        Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: .max, maxSeconds: .infinity, memoryBudgetBytes: 32 * 1024 * 1024, scanToCompletion: false))
    }
    checkEqual(memoryStopped.stopReason, .memoryLimit); checkTrue(memoryStopped.truncated)
    checkTrue(memoryStopped.items.isEmpty)
    let memoryFull = withExtendedLifetime(retainedAllocation) {
        Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: 1, maxSeconds: 0, maxResults: 1, memoryBudgetBytes: 32 * 1024 * 1024))
    }
    checkFalse(memoryFull.truncated); checkTrue(memoryFull.stopReason == nil); checkEqual(memoryFull.totalBytes, 140)
    // A skipped repository is never swept up by deleting its parent candidate.
    try s.write(".git/config", Data("generated repository metadata".utf8), under: nested)
    let policy = Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: .max, maxSeconds: .infinity))
    checkFalse(policy.truncated); checkTrue(policy.stopReason == nil)
    let protected = try unwrap(policy.items.first { $0.path == nested.path })
    checkFalse(protected.canTrash); checkEqual(protected.bytes, 140)
    // One unreadable tree does not make a different fully checked file unselectable.
    let denied = s.files.appendingPathComponent("denied")
    try s.write("child", under: denied)
    try s.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer { try? s.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
    let readable = try s.write("readable", Data("readable".utf8))
    let partial = Scanner().scan(.cleanup, options: .init(home: s.home, roots: [s.files], maxFiles: .max, maxSeconds: .infinity))
    checkTrue(partial.truncated)
    let deniedItem = try unwrap(partial.items.first { $0.path == denied.path })
    let readableItem = try unwrap(partial.items.first { $0.path == readable.path })
    checkFalse(deniedItem.canTrash); checkTrue(readableItem.canTrash)
    // Optional evidence fields remain compatible with reports exported before 0.3.2.
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as! [String: Any]
    for key in ["stopReason", "fileLimit", "timeLimitSeconds"] { object.removeValue(forKey: key) }
    let legacy = try JSONDecoder().decode(ScanReport.self, from: JSONSerialization.data(withJSONObject: object))
    checkEqual(legacy.items.count, full.items.count)
    for report in [limited, timed, cancelled, full, two, boundedResults, memoryStopped, memoryFull, policy, partial] {
        if let reference = report.resultStore { try? ScanResultStore.remove(reference) }
    }
}
