import Foundation
@testable import CleanRoomCore

private final class MergeFixtureReferences: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanResultReference] = []
    func add(_ value: ScanResultReference) { lock.lock(); values.append(value); lock.unlock() }
    func cleanup() { lock.lock(); let owned = values; values = []; lock.unlock(); for value in owned { try? ScanResultStore.remove(value) } }
}
private final class MergeFixtureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstCancelTime: TimeInterval?
    private var highestVisited = 0
    func receive(_ event: SmartCareProgress, cancel: MalwareCancellation? = nil) {
        guard let phase = event.phase, phase.contains("合并") || phase.contains("汇总") else { return }
        lock.lock(); count += 1; highestVisited = max(highestVisited, event.visitedFiles)
        if cancel != nil && firstCancelTime == nil { firstCancelTime = ProcessInfo.processInfo.systemUptime }
        lock.unlock(); cancel?.cancel()
    }
    var snapshot: (count: Int, cancelledAt: TimeInterval?, visited: Int) { lock.lock(); defer { lock.unlock() }; return (count, firstCancelTime, highestVisited) }
}
private struct MergeSemanticProvider: SmartCareScanProviding {
    let modules: [ScanKind: [ScanItem]]
    let owned: MergeFixtureReferences
    var generatedCount = 0
    var home: URL
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        do {
            let store = try ScanResultStore.createTemporary(); owned.add(store.reference)
            if generatedCount > 0 && kind == .cleanup {
                for index in 0..<generatedCount {
                    try autoreleasepool { try store.append(ScanItem(path: home.appendingPathComponent("generated/\(index)").path, category: "generated", bytes: 1, canTrash: true)) }
                }
            } else {
                for item in modules[kind] ?? [] { try store.append(item) }
            }
            try store.flush()
            let count = try store.statistics().totalCount
            var report = ScanReport(kind: kind, visitedFiles: count)
            report.resultStore = store.reference; report.totalItemCount = count
            return report
        } catch { return ScanReport(kind: kind, warnings: [error.localizedDescription], truncated: true, stopReason: .storageError) }
    }
}

func runSmartMergeChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/smart-merge-semantics-" + UUID().uuidString)
    let home = fixture.appendingPathComponent("home"), owned = MergeFixtureReferences()
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { owned.cleanup(); try? fm.removeItem(at: fixture) }
    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
    func item(_ relative: String, _ category: String, _ bytes: Int64, _ canTrash: Bool = true, keeper: String? = nil, identity: FileIdentity? = nil) -> ScanItem {
        ScanItem(path: path(relative), category: category, bytes: bytes, canTrash: canTrash, scopeRoot: home.path, retainedPath: keeper, retainedIdentity: identity)
    }
    func retain(_ report: SmartCareReport) -> SmartCareReport {
        for reference in [report.resultStore, report.readOnlyStore, report.diskCoverage?.issueStore].compactMap({ $0 }) { owned.add(reference) }
        return report
    }
    let keeper = path("Documents/late-protect/original.bin")
    let laterKeeper = path("Downloads/late-original.bin")
    let keeperIdentity = FileIdentity(device: 123, inode: 777, size: 64, modified: 1000)
    let ignored = path("Documents/ignored/future")
    try IgnoreRuleStore(home: home).save([ignored])
    let modules: [ScanKind: [ScanItem]] = [
        .cleanup: [
            item("Documents/parent-first", "parent-first", 90),
            item("Documents/parent-first/child", "later-child", 5),
            item("Documents/child-first/leaf", "child-first", 7),
            item("Documents/child-first", "later-parent", 88),
            item("Documents/资料😀/缓存一", "unicode-a", 14),
            item("Documents/资料😀/缓存一号", "unicode-boundary", 15),
            item("Documents/same-path", "first-id", 11),
            item("Documents/same-path", "different-id", 99),
            item("Documents/late-protect", "early-parent", 100),
            item("Downloads/late-original.bin", "early-original-candidate", 64),
            item("Documents/ignored", "contains-ignored-child", 100),
            item("Documents/ignored/future", "ignored-entry", 1),
            item("Documents/read-only", "readonly-cleanup", 2, false)
        ],
        .duplicates: [
            item("Documents/late-protect/original.bin", "keeper", 64, false, keeper: keeper, identity: keeperIdentity),
            item("Downloads/copy-one.bin", "copy-one", 64, keeper: keeper, identity: keeperIdentity),
            item("Downloads/copy-two.bin", "copy-two", 64, keeper: keeper, identity: keeperIdentity),
            item("Downloads/late-original.bin", "later-keeper", 64, false, keeper: laterKeeper, identity: keeperIdentity)
        ],
        .protection: [item("fixture-status", "readonly-status", 0, false)],
        .applications: [
            item("Documents/late-protect", "late-application-parent", 100),
            item("Documents/late-protect/original.bin", "late-application-original", 64),
            item("Downloads/late-original.bin", "late-application-keeper", 64),
            item("Documents/application-candidate", "unprotected-application", 55),
            item("Documents/read-only", "readonly-application-different-id", 8, false)
        ]
    ]
    let events = MergeFixtureProgress()
    let result = retain(SmartCareService(provider: MergeSemanticProvider(modules: modules, owned: owned, home: home)).scan(options: .init(home: home, includeApplications: true, scanScope: .localMaintenance), progress: { events.receive($0) }))
    checkFalse(result.invalidated); checkFalse(result.incomplete)
    checkEqual(result.totalItemCount, 8); checkEqual(result.totalProcessableBytes, 320)
    checkEqual(result.visitedFiles, modules.values.reduce(0) { $0 + $1.count })
    checkTrue(events.snapshot.count > 0); checkTrue(events.snapshot.visited <= result.visitedFiles)
    let merged = try ScanResultStore(reference: unwrap(result.resultStore))
    let expected: [String: Int64] = [path("Documents/parent-first"):90, path("Documents/child-first/leaf"):7, path("Documents/资料😀/缓存一"):14, path("Documents/资料😀/缓存一号"):15, path("Documents/same-path"):11, path("Downloads/copy-one.bin"):64, path("Downloads/copy-two.bin"):64, path("Documents/application-candidate"):55]
    var actual: [String: Int64] = [:]
    try merged.forEachItem { value in
        checkTrue(value.canTrash); checkEqual(value.scopeRoot, home.path)
        actual[value.path] = value.bytes
        checkFalse(FileSafety.contains(value.path, keeper)); checkFalse(FileSafety.contains(value.path, laterKeeper))
        if value.retainedPath != nil { checkEqual(value.retainedPath, keeper); checkEqual(value.retainedIdentity, keeperIdentity) }
    }
    checkEqual(actual, expected)
    checkEqual(result.readOnlyStoredCount, 5)
    let readonly = try ScanResultStore(reference: unwrap(result.readOnlyStore))
    checkEqual(try readonly.statistics().totalCount, 5)
    var readonlyAtSamePath = 0
    try readonly.forEachItem { value in if value.path == path("Documents/read-only") { readonlyAtSamePath += 1 }; checkFalse(value.canTrash) }
    checkEqual(readonlyAtSamePath, 2)

    // The path boundary is literal, including / and Unicode components.
    let rootStore = try ScanResultStore.createTemporary(); owned.add(rootStore.reference)
    checkEqual(try rootStore.appendIfNoOverlap(ScanItem(path: "/", category: "root", bytes: 1)), true)
    checkEqual(try rootStore.appendIfNoOverlap(ScanItem(path: "/Users/generated", category: "child")), false)
    checkEqual(try rootStore.containsDescendantOrSame("/"), true)
    try rootStore.removeAncestors(of: "/Users/generated")
    checkEqual(try rootStore.statistics().totalCount, 0)
    checkEqual(try rootStore.appendIfNoOverlap(ScanItem(path: "/data/资料😀/a", category: "unicode")), true)
    checkEqual(try rootStore.appendIfNoOverlap(ScanItem(path: "/data-else/资料😀/a", category: "component-boundary")), true)
    checkEqual(try rootStore.containsDescendantOrSame("/dat"), false)
    checkEqual(try rootStore.appendIfNoOverlap(ScanItem(path: "/data", category: "late-parent")), false)

    // Same-size removal must keep accurate maximum statistics before the wide
    // indexes are built, including removal of the final maximum.
    let maximumStore = try ScanResultStore.createTemporary(deferQueryIndexes: true); owned.add(maximumStore.reference)
    for index in 0..<512 { try maximumStore.append(ScanItem(path: path("maximum/top-\(index)"), category: "same-size", bytes: 999)) }
    try maximumStore.append(ScanItem(path: path("maximum/floor"), category: "floor", bytes: 7))
    for index in 0..<512 {
        try maximumStore.removeAncestors(of: path("maximum/top-\(index)/child"))
        if index == 250 { checkEqual(try maximumStore.statistics().maximumBytes, 999) }
    }
    checkEqual(try maximumStore.statistics().maximumBytes, 7); checkEqual(try maximumStore.statistics().totalCount, 1)
    try maximumStore.removeAncestors(of: path("maximum/floor"))
    checkEqual(try maximumStore.statistics().maximumBytes, 0); checkEqual(try maximumStore.statistics().totalBytes, 0)

    // A committed external writer invalidates the first writer's negative
    // parent memo; a new transaction must see its newly inserted ancestor.
    let first = try ScanResultStore.createTemporary(); owned.add(first.reference)
    checkEqual(try first.appendIfNoOverlap(ScanItem(path: path("memo/parent/first"), category: "first")), true)
    try first.flush()
    let second = try ScanResultStore(reference: first.reference, readOnly: false)
    try second.append(ScanItem(path: path("memo/parent"), category: "external-parent")); try second.flush()
    checkEqual(try first.appendIfNoOverlap(ScanItem(path: path("memo/parent/second"), category: "must-refuse")), false)
    try first.flush(); checkEqual(try first.statistics().totalCount, 2)

    // Swift String equality folds canonical equivalents; SQLite BINARY keys do
    // not. A negative memo for the NFC parent cannot cover an existing NFD key.
    let unicodeMemo = try ScanResultStore.createTemporary(); owned.add(unicodeMemo.reference)
    // URL.appendingPathComponent may compose NFD; keep literal UTF8 keys here.
    let nfd = home.path + "/memo-unicode/e\u{301}", nfc = home.path + "/memo-unicode/é"
    checkFalse(nfd.utf8.elementsEqual(nfc.utf8))
    try unicodeMemo.append(ScanItem(path: nfd, category: "NFD parent"))
    checkEqual(try unicodeMemo.appendIfNoOverlap(ScanItem(path: nfc + "/other", category: "NFC child")), true)
    checkEqual(try unicodeMemo.appendIfNoOverlap(ScanItem(path: nfd + "/child", category: "NFD must refuse")), false)
    try unicodeMemo.flush(); checkEqual(try unicodeMemo.statistics().totalCount, 2)

    // Interrupt CREATE INDEX inside SQLite's VM (not only its initial guard),
    // retain all statistics, then retry and page successfully.
    let deferred = try ScanResultStore.createTemporary(deferQueryIndexes: true); owned.add(deferred.reference)
    for index in 0..<6000 {
        try autoreleasepool { try deferred.append(ScanItem(path: path("deferred/\(index)"), category: "DDL", bytes: Int64(index % 509), canTrash: index >= 5996)) }
    }
    try deferred.flush()
    let before = try deferred.statistics()
    var checks = 0, interrupted = false
    do { try deferred.prepareForPaging(isCancelled: { checks += 1; return checks >= 3 }) }
    catch ScanStoreError.cancelled { interrupted = true }
    checkTrue(interrupted); checkTrue(checks >= 3)
    checkEqual(try deferred.statistics().totalCount, before.totalCount)
    checkEqual(try deferred.statistics().totalBytes, before.totalBytes)
    try deferred.prepareForPaging()
    checkEqual(try deferred.page(limit: 200).items.count, 200)
    checkEqual(try deferred.page(processableOnly: true).filteredCount, 4)

    // A deferred source has no can_trash sorting index. Its first filtered step
    // must be cancellable while skipping thousands of read-only records.
    let filtered = try ScanResultStore.createTemporary(deferQueryIndexes: true); owned.add(filtered.reference)
    for index in 0..<6000 {
        try autoreleasepool { try filtered.append(ScanItem(path: path("filtered/\(index)"), category: "filtered", canTrash: index >= 5996)) }
    }
    try filtered.flush()
    var filterChecks = 0, delivered = 0, filterCancelled = false
    do { try filtered.forEachItem(processableOnly: true, isCancelled: { filterChecks += 1; return filterChecks >= 3 }) { _ in delivered += 1 } }
    catch ScanStoreError.cancelled { filterCancelled = true }
    checkTrue(filterCancelled); checkTrue(filterChecks >= 3); checkTrue(delivered < 4)
    checkEqual(try filtered.statistics().totalCount, 6000)

    // Trigger cancellation from a real merge-phase event, preserve partial
    // output references and avoid mislabelling SQL cancellation as corruption.
    try IgnoreRuleStore(home: home).save([])
    let token = MalwareCancellation(), cancelEvents = MergeFixtureProgress()
    let cancelled = retain(SmartCareService(provider: MergeSemanticProvider(modules: [:], owned: owned, generatedCount: 5000, home: home)).scan(options: .init(home: home, scanScope: .localMaintenance), cancellation: token, progress: { cancelEvents.receive($0, cancel: token) }))
    checkTrue(cancelEvents.snapshot.count > 0); checkTrue(cancelled.cancelled); checkTrue(cancelled.incomplete); checkFalse(cancelled.invalidated)
    checkTrue(cancelled.resultStore != nil)
    if let when = cancelEvents.snapshot.cancelledAt { checkLessThan(ProcessInfo.processInfo.systemUptime - when, 3.0) }
    checkTrue(cancelled.totalItemCount < 5000)
    checkTrue(cancelled.modules.dropFirst().allSatisfy(\.skipped))
    print("PASS SmartCare merge semantics, late/shared keepers, first-wins boundaries, cross-writer memo, SQLite VM cancellation")
}
