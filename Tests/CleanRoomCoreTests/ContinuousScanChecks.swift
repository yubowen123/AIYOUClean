import Foundation
import Darwin
@testable import CleanRoomCore

private enum ContinuousScanFixtureError: LocalizedError {
    case io(Int32, String)
    var errorDescription: String? {
        if case .io(let code, let path) = self { return "生成连续扫描夹具失败（errno \(code)）：\(path)" }; return nil
    }
}
private struct ContinuousModuleObservation: Sendable {
    let kind: ScanKind
    let continuous: Bool
    let unlimitedDeadline: Bool
    let previewCount: Int
    let totalCount: Int
    let processableCount: Int
    let visited: Int
    let truncated: Bool
    let stopReason: ScanStopReason?
}
private final class ContinuousFixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [ContinuousModuleObservation] = []
    private var childReferences: [ScanResultReference] = []
    func record(_ kind: ScanKind, options: ScanOptions, deadline: TimeInterval, report: ScanReport) {
        lock.lock(); defer { lock.unlock() }
        observations.append(ContinuousModuleObservation(kind: kind, continuous: options.scanToCompletion, unlimitedDeadline: deadline.isInfinite, previewCount: report.items.count, totalCount: report.totalItemCount ?? report.items.count, processableCount: report.processableItemCount ?? report.items.filter(\.canTrash).count, visited: report.visitedFiles, truncated: report.truncated, stopReason: report.stopReason))
        if let reference = report.resultStore { childReferences.append(reference) }
    }
    var modules: [ContinuousModuleObservation] { lock.lock(); defer { lock.unlock() }; return observations }
    var references: [ScanResultReference] { lock.lock(); defer { lock.unlock() }; return childReferences }
}
private struct RealFileContinuousSmartCareProvider: SmartCareScanProviding {
    let recorder: ContinuousFixtureRecorder
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        let report: ScanReport
        switch kind {
        case .cleanup, .duplicates:
            report = Scanner().scan(kind, options: options, progress: progress, isCancelled: { cancellation.isCancelled })
        case .protection:
            // Never execute status commands or inspect the real home in this fixture.
            report = ScanReport(kind: kind, items: [ScanItem(path: "/generated/continuous-fixture/security-state", name: "生成夹具状态", category: "只读mock", detail: "未执行系统命令或实际查杀", canTrash: false)])
        default:
            report = ScanReport(kind: kind, warnings: ["本夹具不执行该模块"], truncated: true)
        }
        recorder.record(kind, options: options, deadline: deadline, report: report)
        return report
    }
}

/// End-to-end production-scanner regression. Only this UUID fake home and owned
/// temporary result stores are created; no TrashManager or user-file cleanup runs.
func runContinuousScanChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/continuous-scan-" + UUID().uuidString)
    let home = fixture.appendingPathComponent("home")
    let cache = home.appendingPathComponent("Library/Caches/GeneratedCache")
    let downloads = home.appendingPathComponent("Downloads")
    let recorder = ContinuousFixtureRecorder()
    var ownedReferences: [ScanResultReference] = []
    defer {
        for reference in ownedReferences { try? ScanResultStore.remove(reference) }
        for reference in recorder.references { try? ScanResultStore.remove(reference) }
        try? fm.removeItem(at: fixture)
    }
    try fm.createDirectory(at: cache.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
    func generatedFiles(in directory: URL, first: Int, count: Int, data: Data, prefix: String, width: Int) throws {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ContinuousScanFixtureError.io(errno, directory.path) }
        defer { close(parent) }
        for index in first..<(first + count) {
            try autoreleasepool {
                let number = String(index)
                let name = prefix + String(repeating: "0", count: max(0, width - number.count)) + number
                let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw ContinuousScanFixtureError.io(errno, directory.path + "/" + name) }
                defer { close(fd) }
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw ContinuousScanFixtureError.io(errno, directory.path + "/" + name) }
                        offset += written
                    }
                }
            }
        }
    }
    let cacheFileCount = 50_001, duplicateCount = 2602
    let cacheContents = Data([0x78]), duplicateContents = Data("DUPLICATE".utf8)
    for first in stride(from: 0, to: cacheFileCount, by: 500) {
        let bucket = cache.appendingPathComponent("nested/bucket-\(first / 500)")
        try fm.createDirectory(at: bucket, withIntermediateDirectories: false)
        try generatedFiles(in: bucket, first: first, count: min(500, cacheFileCount - first), data: cacheContents, prefix: "file-", width: 5)
    }
    try generatedFiles(in: downloads, first: 0, count: duplicateCount, data: duplicateContents, prefix: "copy-", width: 4)
    let keeper = downloads.appendingPathComponent("copy-0000")
    let keeperIdentity = try unwrap(FileSafety.identity(keeper))
    let lastCopy = downloads.appendingPathComponent("copy-2601")
    let service = SmartCareService(provider: RealFileContinuousSmartCareProvider(recorder: recorder))
    // Legacy cap preferences must not resurrect an overall deadline, a 50k
    // visit cutoff or a one-row result cutoff in continuous SmartCare.
    let combined = service.scan(options: SmartCareOptions(home: home, maxFiles: 50_000, maxSeconds: 0, maxResults: 1, scanScope: .localMaintenance))
    for reference in [combined.resultStore, combined.readOnlyStore, combined.diskCoverage?.issueStore].compactMap({ $0 }) { ownedReferences.append(reference) }
    checkEqual(recorder.modules.map(\.kind), [.cleanup, .duplicates, .protection])
    checkTrue(recorder.modules.allSatisfy { $0.continuous && $0.unlimitedDeadline })
    checkTrue(recorder.modules.allSatisfy { !$0.truncated && $0.stopReason == nil && $0.previewCount <= 200 })
    let cleanupObservation = try unwrap(recorder.modules.first { $0.kind == .cleanup })
    checkTrue(cleanupObservation.visited > 50_000); checkEqual(cleanupObservation.totalCount, 1); checkEqual(cleanupObservation.processableCount, 1)
    let duplicatesObservation = try unwrap(recorder.modules.first { $0.kind == .duplicates })
    checkEqual(duplicatesObservation.totalCount, duplicateCount); checkEqual(duplicatesObservation.processableCount, duplicateCount - 1)
    let cleanupSummary = try unwrap(combined.modules.first { $0.kind == .cleanup })
    let duplicateSummary = try unwrap(combined.modules.first { $0.kind == .duplicates })
    checkFalse(cleanupSummary.incomplete); checkFalse(cleanupSummary.skipped); checkTrue(cleanupSummary.visitedFiles > 50_000)
    checkEqual(duplicateSummary.count, duplicateCount); checkEqual(duplicateSummary.readOnlyCount, 1); checkEqual(duplicateSummary.processableCount, duplicateCount - 1)
    checkFalse(duplicateSummary.incomplete); checkFalse(duplicateSummary.skipped)
    checkEqual(combined.modules.count, 3); checkTrue(combined.modules.allSatisfy { !$0.skipped && !$0.incomplete })
    checkTrue(combined.visitedFiles > 50_000); checkFalse(combined.incomplete); checkFalse(combined.cancelled); checkFalse(combined.invalidated)
    checkEqual(combined.totalItemCount, 2602); checkTrue(combined.items.count <= 200)
    let combinedReference = try unwrap(combined.resultStore), reader = try ScanResultStore(reference: combinedReference)
    let combinedStatistics = try reader.statistics()
    checkEqual(combinedStatistics.totalCount, 2602); checkEqual(combinedStatistics.processableCount, 2602)
    let expectedBytes = Int64(cacheFileCount) + Int64(duplicateCount - 1) * Int64(duplicateContents.count)
    checkEqual(combined.totalProcessableBytes, expectedBytes); checkEqual(combinedStatistics.processableBytes, expectedBytes)
    var cacheRows = 0, copyRows = 0, keepersInActions = 0
    try reader.forEachItem(processableOnly: true) { item in
        checkTrue(item.canTrash)
        if item.path == cache.path { cacheRows += 1; checkEqual(item.bytes, Int64(cacheFileCount)); checkEqual(item.identity, FileSafety.identity(cache)) }
        else {
            copyRows += 1
            checkEqual(item.retainedPath, keeper.path); checkEqual(item.retainedIdentity, keeperIdentity)
            checkEqual(item.identity, FileSafety.identity(URL(fileURLWithPath: item.path)))
            checkEqual(item.bytes, Int64(duplicateContents.count)); checkEqual(item.scopeRoot, downloads.path)
            if item.path == keeper.path { keepersInActions += 1 }
        }
    }
    checkEqual(cacheRows, 1); checkEqual(copyRows, 2601); checkEqual(keepersInActions, 0)
    let finalOffset = ((combinedStatistics.totalCount - 1) / 200) * 200
    let finalPage = try reader.page(offset: finalOffset, limit: 200, largestFirst: false, processableOnly: true)
    checkEqual(finalPage.filteredCount, 2602); checkEqual(finalPage.items.count, 2)
    checkTrue(finalPage.items.allSatisfy { $0.canTrash && $0.identity != nil })
    checkTrue(finalPage.items.contains { $0.path == lastCopy.path }); checkTrue(finalPage.items.contains { $0.path == cache.path })
    // Public Scanner defaults to continuous even if old diagnostic cap values
    // are explicitly supplied; only preview rows stay bounded in memory.
    let ordinary = Scanner().scan(.downloads, options: ScanOptions(home: home, roots: [downloads], maxFiles: 1, maxSeconds: 0, maxResults: 1))
    if let reference = ordinary.resultStore { ownedReferences.append(reference) }
    checkFalse(ordinary.truncated); checkTrue(ordinary.stopReason == nil)
    checkTrue(ordinary.fileLimit == nil); checkTrue(ordinary.timeLimitSeconds == nil)
    checkEqual(ordinary.totalItemCount, duplicateCount); checkEqual(ordinary.processableItemCount, duplicateCount)
    checkEqual(ordinary.visitedFiles, duplicateCount); checkTrue(ordinary.items.count <= 200)
    let ordinaryReader = try ScanResultStore(reference: unwrap(ordinary.resultStore))
    let ordinaryLast = try ordinaryReader.page(offset: 2600, largestFirst: false)
    checkEqual(ordinaryLast.filteredCount, duplicateCount); checkEqual(ordinaryLast.items.count, 2)
    checkTrue(ordinaryLast.items.contains { $0.path == lastCopy.path })
    let cancellation = MalwareCancellation()
    let cancelled = Scanner().scan(.downloads, options: ScanOptions(home: home, roots: [downloads], maxFiles: 1, maxSeconds: 0, maxResults: 1), progress: { _,_ in cancellation.cancel() }, isCancelled: { cancellation.isCancelled })
    if let reference = cancelled.resultStore { ownedReferences.append(reference) }
    checkTrue(cancellation.isCancelled); checkTrue(cancelled.truncated); checkEqual(cancelled.stopReason, .cancelled)
    checkTrue(cancelled.visitedFiles > 0); checkTrue(cancelled.visitedFiles < duplicateCount)
    checkTrue((cancelled.totalItemCount ?? cancelled.items.count) < duplicateCount)
    let stillPresent = MetadataTreeWalker.summarize(root: downloads, shouldStop: { false }, onVisit: { _ in })
    checkTrue(stillPresent.complete); checkEqual(stillPresent.visitedEntries, duplicateCount)
    checkEqual(stillPresent.logicalBytes, Int64(duplicateCount * duplicateContents.count))
    checkEqual(try Data(contentsOf: keeper), duplicateContents); checkEqual(try Data(contentsOf: lastCopy), duplicateContents)
    print("PASS continuous integration: 50001 nested cache files + 2602 duplicates, complete SmartCare/disk tail pages/keeper identities and in-flight cancellation")
}
