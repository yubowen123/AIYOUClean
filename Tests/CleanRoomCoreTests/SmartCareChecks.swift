import Foundation
import Darwin
@testable import CleanRoomCore

private final class SmartCareFixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ScanKind, Bool, Bool)] = []
    func record(_ kind: ScanKind, options: ScanOptions, deadline: TimeInterval) { lock.lock(); entries.append((kind, options.scanToCompletion, deadline.isInfinite)); lock.unlock() }
    var kinds: [ScanKind] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.0 } }
    var allComplete: Bool { lock.lock(); defer { lock.unlock() }; return entries.allSatisfy { $0.1 && $0.2 } }
}
private struct FixtureSmartCareProvider: SmartCareScanProviding {
    let home: URL
    var cancelAfterCleanup = false
    var partialCleanup = false
    var recorder: SmartCareFixtureRecorder?
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        recorder?.record(kind, options: options, deadline: deadline)
        // These deliberately omit resultStore: mock/legacy reports must still merge.
        if kind == .protection { return ScanReport(kind: kind, items: [ScanItem(path: "/generated/security-state", name: "模拟安全状态", category: "fixture", detail: "只读状态，不是查杀", canTrash: false)]) }
        if kind == .applications {
            let cacheChild = home.appendingPathComponent("Library/Caches/fixture/child"), keeper = home.appendingPathComponent("Downloads/a")
            return ScanReport(kind: kind, items: [ScanItem(path: cacheChild.path, category: "fixture-app-support", bytes: 5, canTrash: true, identity: FileSafety.identity(cacheChild), scopeRoot: cacheChild.deletingLastPathComponent().path), ScanItem(path: keeper.path, category: "fixture-keeper", bytes: 10, canTrash: true, identity: FileSafety.identity(keeper), scopeRoot: keeper.deletingLastPathComponent().path)])
        }
        var result = Scanner().scan(kind, options: options, progress: progress, isCancelled: { cancellation.isCancelled })
        if kind == .cleanup && partialCleanup {
            result.truncated = true; result.stopReason = .memoryLimit
            result.warnings.append("generated permission fixture: Operation not permitted (errno=1)")
        }
        if kind == .cleanup && cancelAfterCleanup { cancellation.cancel() }
        return result
    }
}
private struct FixtureDiskSmartCareProvider: SmartCareScanProviding {
    let home: URL
    let recorder: SmartCareFixtureRecorder
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        recorder.record(kind, options: options, deadline: deadline)
        do {
            let store = try ScanResultStore.createTemporary()
            switch kind {
            case .cleanup:
                for index in 0..<2600 { try store.append(ScanItem(path: home.appendingPathComponent("generated/cleanup/item-\(index)").path, category: "fixture-cleanup", bytes: 2, canTrash: true)) }
            case .duplicates:
                let keeper = home.appendingPathComponent("generated/duplicates/a").path
                try store.append(ScanItem(path: keeper, category: "保留原件", bytes: 3, retainedPath: keeper))
                for name in ["b", "c"] { try store.append(ScanItem(path: home.appendingPathComponent("generated/duplicates/\(name)").path, category: "重复副本", bytes: 3, canTrash: true, retainedPath: keeper)) }
            default:
                try store.append(ScanItem(path: "/generated/security-state", category: "fixture-readonly", detail: "模拟只读状态"))
            }
            try store.flush()
            var report = ScanReport(kind: kind, items: try store.page(limit: 1).items, visitedFiles: kind == .cleanup ? 2600 : 3)
            report.resultStore = store.reference
            return report
        } catch { return ScanReport(kind: kind, warnings: [error.localizedDescription], truncated: true, stopReason: .configurationError) }
    }
}
func runSmartCareChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = project.appendingPathComponent(".test-fixtures/smart-care-" + UUID().uuidString), home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    var reports: [ScanResultReference] = []
    defer { for reference in reports { try? ScanResultStore.remove(reference) }; try? fm.removeItem(at: root) }
    func retained(_ report: SmartCareReport) -> SmartCareReport { for reference in [report.resultStore, report.readOnlyStore, report.diskCoverage?.issueStore].compactMap({ $0 }) { reports.append(reference) }; return report }
    func candidates(_ report: SmartCareReport) throws -> [ScanItem] {
        guard let reference = report.resultStore else { return report.items }
        var items: [ScanItem] = []
        try ScanResultStore(reference: reference).forEachItem(processableOnly: true) { items.append($0) }
        return items
    }
    @discardableResult func fixture(_ relative: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(relative); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url); return url
    }
    let store = IgnoreRuleStore(home: home)
    checkEqual(try store.load(), [])
    let ignored = home.appendingPathComponent("Library/Caches/ignored")
    try store.save([ignored.path + "/./", ignored.path, home.appendingPathComponent("Downloads/../Documents").path])
    checkEqual(try store.load().count, 2)
    checkTrue(IgnoreRuleStore.isExcluded(ignored.appendingPathComponent("deep/file").path, by: [ignored.path]))
    checkFalse(IgnoreRuleStore.isExcluded(ignored.path + "-sibling", by: [ignored.path]))
    checkTrue(IgnoreRuleStore.isExcluded(home.path, by: ["/"]))
    checkFalse(IgnoreRuleStore.isExcluded(home.path, by: []))
    checkThrows(try store.save(["relative/path"]))
    checkThrows(try store.save(["~/Documents"]))
    checkThrows(try store.save(["/bad\npath"]))
    checkThrows(try store.save((0...500).map { "/fixture-\($0)" }))
    var metadata = stat(); checkEqual(lstat(store.fileURL.path, &metadata), 0); checkEqual(metadata.st_mode & 0o777, 0o600)
    let cache = try fixture("Library/Caches/fixture/child", "CACHE")
    let ignoredFile = try fixture("Library/Caches/ignored/child", "KEEP")
    try fixture("Downloads/a", "DUPLICATE FIXTURE")
    let duplicate = try fixture("Downloads/b", "DUPLICATE FIXTURE")
    try fixture("Documents/not-in-default-duplicate-scope", "DUPLICATE FIXTURE")
    let service = SmartCareService(provider: FixtureSmartCareProvider(home: home))
    let report = retained(service.scan(options: SmartCareOptions(home: home, includeApplications: true, scanScope: .localMaintenance)))
    let items = try candidates(report)
    checkEqual(report.modules.map(\.kind), [.cleanup, .duplicates, .protection, .applications])
    checkTrue(items.contains { $0.path == duplicate.path })
    checkFalse(items.contains { $0.path == home.appendingPathComponent("Downloads/a").path })
    checkFalse(items.contains { FileSafety.contains(ignored.path, $0.path) })
    checkFalse(items.contains { $0.path.contains("Documents/not-in-default") })
    checkTrue(report.modules.first { $0.kind == .protection }?.observations.contains { $0.contains("模拟安全状态") } == true)
    checkTrue(report.items.count <= 200); checkEqual(report.totalItemCount, items.count)
    checkFalse(items.contains { a in items.contains { b in a.path != b.path && (FileSafety.contains(a.path, b.path) || FileSafety.contains(b.path, a.path)) } })
    checkTrue(fm.fileExists(atPath: cache.path)); checkTrue(fm.fileExists(atPath: ignoredFile.path)); checkTrue(fm.fileExists(atPath: duplicate.path))
    let originalRules = try store.load()
    try store.save(originalRules + [cache.path])
    let ignoredChild = retained(service.scan(options: SmartCareOptions(home: home, includeApplications: true, scanScope: .localMaintenance)))
    let ignoredItems = try candidates(ignoredChild)
    checkFalse(ignoredItems.contains { FileSafety.contains($0.path, cache.path) })
    try store.save(originalRules)
    let cancellation = MalwareCancellation(), cancelledRecorder = SmartCareFixtureRecorder()
    let cancelled = retained(SmartCareService(provider: FixtureSmartCareProvider(home: home, cancelAfterCleanup: true, recorder: cancelledRecorder)).scan(options: SmartCareOptions(home: home, scanScope: .localMaintenance), cancellation: cancellation))
    checkTrue(cancelled.cancelled); checkTrue(cancelled.incomplete); checkTrue(cancelled.modules.dropFirst().allSatisfy(\.skipped))
    checkEqual(cancelledRecorder.kinds, [.cleanup])
    checkTrue(cancelled.modules.dropFirst().allSatisfy { $0.warnings.contains { $0.contains("用户已取消") } })
    let recorder = SmartCareFixtureRecorder()
    let limited = retained(SmartCareService(provider: FixtureDiskSmartCareProvider(home: home, recorder: recorder)).scan(options: SmartCareOptions(home: home, maxFiles: 1, maxSeconds: 0.001, maxResults: 1, scanScope: .localMaintenance)))
    checkEqual(recorder.kinds, [.cleanup, .duplicates, .protection]); checkTrue(recorder.allComplete)
    checkEqual(limited.totalItemCount, 2602); checkEqual(limited.totalProcessableBytes, 5206)
    checkEqual(limited.items.count, 200); checkFalse(limited.incomplete)
    if let reference = limited.resultStore {
        let disk = try ScanResultStore(reference: reference)
        checkEqual(try disk.statistics().totalCount, 2602)
        let laterPage = try disk.page(offset: 2400, limit: 200, processableOnly: true)
        checkEqual(laterPage.items.count, 200); checkEqual(laterPage.filteredCount, 2602)
    } else { checkTrue(false) }
    let partialRecorder = SmartCareFixtureRecorder()
    let partial = retained(SmartCareService(provider: FixtureSmartCareProvider(home: home, partialCleanup: true, recorder: partialRecorder)).scan(options: SmartCareOptions(home: home, scanScope: .localMaintenance)))
    checkTrue(partial.incomplete); checkTrue(partial.modules.first?.permissionRequired == true)
    checkEqual(partialRecorder.kinds, [.cleanup, .duplicates, .protection]); checkTrue(partialRecorder.allComplete)
    checkTrue(partial.modules.contains { $0.kind == .duplicates && !$0.skipped })
    checkTrue(partial.modules.contains { $0.kind == .protection && !$0.skipped })
    let partialItems = try candidates(partial)
    checkTrue(partialItems.contains { $0.path == duplicate.path })
    if let lease = WorkBudget.tryAcquire("generated competing fixture") {
        let busyRecorder = SmartCareFixtureRecorder()
        let busy = retained(SmartCareService(provider: FixtureSmartCareProvider(home: home, recorder: busyRecorder)).scan(options: SmartCareOptions(home: home, scanScope: .localMaintenance)))
        checkEqual(busyRecorder.kinds, [.cleanup, .duplicates, .protection])
        let busyItems = try candidates(busy)
        checkTrue(busy.incomplete); checkTrue(busyItems.isEmpty)
        lease.release()
    }
    try Data("{broken fixture".utf8).write(to: store.fileURL)
    let corrupt = retained(service.scan(options: SmartCareOptions(home: home, scanScope: .localMaintenance)))
    checkTrue(corrupt.invalidated); checkTrue(corrupt.items.isEmpty); checkTrue(corrupt.modules.isEmpty)
    try store.save([])
    let symlinkHome = root.appendingPathComponent("symlink-home"), elsewhere = root.appendingPathComponent("elsewhere")
    try fm.createDirectory(at: symlinkHome.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: symlinkHome.appendingPathComponent("Library/Application Support/AIYOUClean"), withDestinationURL: elsewhere)
    checkThrows(try IgnoreRuleStore(home: symlinkHome).save(["/fixture"]))
    checkThrows(try { _ = try IgnoreRuleStore(home: symlinkHome).load() }())
    checkFalse(fm.fileExists(atPath: elsewhere.appendingPathComponent("ignore-rules.json").path))
    print("PASS ignore store and complete disk-paged SmartCare generated fixtures")
}
