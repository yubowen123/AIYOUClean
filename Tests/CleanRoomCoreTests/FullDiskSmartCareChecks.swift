import Foundation
import Darwin
@testable import CleanRoomCore

private struct FullScopeFixtureProvider: SmartCareScanProviding {
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval,
              progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        if kind == .protection {
            return ScanReport(kind: kind, items: [ScanItem(path: "/generated/full-scope/security", category: "生成只读状态", detail: "无实际系统命令")])
        }
        // Selected-folder integration must not expand into the actual app/cache locations.
        return ScanReport(kind: kind, warnings: ["unexpected fixture provider call"], truncated: true)
    }
}

func runFullDiskSmartCareChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/full-smart-care-" + UUID().uuidString)
    let home = fixture.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    var references: [ScanResultReference] = []
    defer {
        for reference in references { try? ScanResultStore.remove(reference) }
        try? fm.removeItem(at: fixture)
    }
    func retain(_ value: SmartCareReport) -> SmartCareReport {
        references += [value.resultStore, value.readOnlyStore, value.diskCoverage?.issueStore].compactMap { $0 }
        return value
    }
    @discardableResult func write(_ relative: String, _ data: Data = Data("cross-folder-duplicate".utf8)) throws -> URL {
        let path = home.appendingPathComponent(relative)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path); return path
    }
    let documents = try write("Documents/original.dat")
    let desktop = try write("Desktop/copy.dat")
    let movies = try write("Movies/copy.dat")
    let app = try write("Applications/Fixture.app/Contents/readonly.dat")
    try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: app.path)
    let large = home.appendingPathComponent("Movies/large-generated.bin")
    let fd = open(large.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw CheckError.missingValue }
    checkEqual(ftruncate(fd, 101_000_000), 0); close(fd)
    let ignored = try write("Custom/ignored.dat")
    try fm.createSymbolicLink(at: home.appendingPathComponent("do-not-follow"), withDestinationURL: fixture)
    try IgnoreRuleStore(home: home).save([ignored.path])
    checkEqual(SmartCareOptions().scanScope, .allLocalDisks)
    let service = SmartCareService(provider: FullScopeFixtureProvider())
    let report = retain(service.scan(options: .init(home: home, includeApplications: true, maxFiles: 1, maxSeconds: 0, maxResults: 1,
                                                    scanScope: .selectedFolders, roots: [home])))
    checkFalse(report.cancelled); checkFalse(report.invalidated); checkFalse(report.incomplete)
    checkTrue(report.modules.filter { $0.kind == .largeFiles || $0.kind == .duplicates }.allSatisfy { !$0.incomplete })
    checkEqual(report.modules.map(\.kind), [.cleanup, .largeFiles, .duplicates, .protection])
    let coverage = try unwrap(report.diskCoverage)
    checkEqual(coverage.roots, [home.path]); checkTrue(coverage.regularFiles >= 6)
    checkEqual(coverage.skippedLinkEntries, 1); checkTrue(coverage.excludedEntries >= 1)
    checkTrue(report.items.count <= 200); checkTrue(report.totalItemCount >= 3)
    var processable: [ScanItem] = []
    try ScanResultStore(reference: try unwrap(report.resultStore)).forEachItem { processable.append($0) }
    checkTrue(processable.contains { $0.path == large.path })
    checkTrue(processable.contains { $0.path == desktop.path })
    checkTrue(processable.contains { $0.path == movies.path })
    checkFalse(processable.contains { $0.path == app.path || $0.path == ignored.path || $0.path == home.path || $0.path == "/" })
    checkTrue(report.modules.first { $0.kind == .duplicates }?.visitedFiles == coverage.regularFiles)
    let readOnly = try ScanResultStore(reference: try unwrap(report.readOnlyStore))
    var readOnlyFound = false
    try readOnly.forEachItem { item in if item.path == app.path { readOnlyFound = true }; checkFalse(item.canTrash) }
    checkTrue(readOnlyFound); checkEqual(try readOnly.statistics().totalCount, report.readOnlyStoredCount)
    let issues = try ScanResultStore(reference: try unwrap(coverage.issueStore))
    checkEqual(try issues.statistics().totalCount, coverage.issueCount)
    checkTrue(coverage.issueCount >= 2)
    checkTrue(fm.fileExists(atPath: documents.path)); checkTrue(fm.fileExists(atPath: movies.path))
    let noRoots = retain(service.scan(options: .init(home: home, scanScope: .selectedFolders)))
    checkTrue(noRoots.invalidated); checkTrue(noRoots.diskCoverage == nil); checkTrue(noRoots.modules.isEmpty)
    let explicit = FullDiskFileScanner().scan(plan: .init(roots: [home]), home: home, excludedPaths: [home.path])
    references += [explicit.largeFiles.resultStore, explicit.duplicates.resultStore, explicit.coverage.issueStore].compactMap { $0 }
    checkEqual(explicit.coverage.regularFiles, 0); checkTrue(explicit.coverage.excludedEntries >= 1)

    // Round trips preserve /private rather than silently rewriting it to /var.
    // These are metadata-only fake paths; no private source is opened.
    checkEqual(ScanLexicalPath.normalize("/private/var/generated/a/../b"), "/private/var/generated/b")
    let index = try ScanCandidateIndex.createTemporary(); defer { try? index.dispose() }
    let first = FileIdentity(device: 1, inode: 1, size: 8, modified: 1)
    let second = FileIdentity(device: 1, inode: 2, size: 8, modified: 1)
    try index.append(path: "/private/var/generated/a", rootPath: "/", identity: first, bytes: 8)
    try index.append(path: "/private/var/generated/b", rootPath: "/", identity: second, bytes: 8)
    var literalCount = 0
    try index.forEachDuplicateSizeCandidate { item in checkTrue(item.path.hasPrefix("/private/var/")); literalCount += 1 }
    checkEqual(literalCount, 2)
    print("PASS full-scope SmartCare: cross-Documents/Desktop/Movies, read-only app, explicit roots/ignore, coverage/issues, no real disk scan")
}
