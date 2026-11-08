import Foundation
import Darwin
import CryptoKit
@testable import CleanRoomCore

func runFullDiskFileChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = project.appendingPathComponent(".test-fixtures/full-disk-files-" + UUID().uuidString)
    let home = fixture.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    var references: [ScanResultReference] = []
    defer {
        for reference in references {
            do { try ScanResultStore.remove(reference) }
            catch { checkTrue(false, file: #filePath, line: #line) }
            checkFalse(fm.fileExists(atPath: reference.path))
        }
    }
    @discardableResult func file(_ path: URL, bytes: Int, value: UInt8 = 0x41) throws -> URL {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: value, count: bytes).write(to: path); return path
    }
    func scan(_ plan: FullDiskScanPlan, home: URL, threshold: Int64 = 128,
              cancellation: MalwareCancellation = MalwareCancellation(),
              progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }) -> FullDiskFileReport {
        let report = FullDiskFileScanner().scan(plan: plan, home: home, largeFileBytes: threshold, cancellation: cancellation, progress: progress)
        references.append(contentsOf: [report.largeFiles.resultStore, report.duplicates.resultStore, report.coverage.issueStore].compactMap { $0 })
        return report
    }
    func rows(_ report: ScanReport) throws -> [ScanItem] {
        guard let reference = report.resultStore else { return report.items }
        // Test scenarios here are deliberately small. Production uses pages;
        // the separate 260-item case below verifies all rows without an array.
        var result: [ScanItem] = []
        try ScanResultStore(reference: reference).forEachItem { result.append($0) }
        return result
    }
    let documents = home.appendingPathComponent("Documents"), desktop = home.appendingPathComponent("Desktop")
    let movies = home.appendingPathComponent("Movies"), custom = home.appendingPathComponent("Custom")
    let a = try file(documents.appendingPathComponent("a.dat"), bytes: 64)
    let b = try file(desktop.appendingPathComponent("b.dat"), bytes: 64)
    let c = try file(movies.appendingPathComponent("c.dat"), bytes: 64)
    let d = try file(custom.appendingPathComponent("d.dat"), bytes: 64)
    let app = try file(documents.appendingPathComponent("Sample.app/Contents/Resources/inside.dat"), bytes: 64)
    let large = try file(movies.appendingPathComponent("large.bin"), bytes: 1024, value: 0x7F)
    let old = try file(custom.appendingPathComponent("old.txt"), bytes: 1, value: 0x11)
    for path in [old, app] { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: path.path) }
    try fm.linkItem(at: a, to: documents.appendingPathComponent("a-hardlink.dat"))
    let ignored = try file(documents.appendingPathComponent("ignored/not-read.dat"), bytes: 64)
    try IgnoreRuleStore(home: home).save([ignored.deletingLastPathComponent().path])
    let outside = try file(fixture.appendingPathComponent("outside/not-in-roots.dat"), bytes: 64)
    try fm.createSymbolicLink(at: documents.appendingPathComponent("outside-link"), withDestinationURL: outside.deletingLastPathComponent())
    // A similarly named user folder must not be mistaken for an owned index.
    try file(documents.appendingPathComponent("AIYOUClean-results-not-a-session/personal.dat"), bytes: 17, value: 0x31)
    let denied = try file(documents.appendingPathComponent("denied/secret.dat"), bytes: 64)
    let unreadable = try file(documents.appendingPathComponent("unreadable.dat"), bytes: 64)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.deletingLastPathComponent().path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
    }
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.deletingLastPathComponent().path)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    let plan = FullDiskScopePlanner.selectedFolders([documents, desktop, movies, custom, documents], home: home)
    let report = scan(plan, home: home)
    checkEqual(report.coverage.roots.count, 4)
    checkFalse(report.coverage.cancelled)
    checkTrue(report.coverage.skippedLinkEntries >= 1); checkTrue(report.coverage.excludedEntries >= 1)
    if geteuid() != 0 {
        checkTrue(report.coverage.incomplete); checkTrue(report.coverage.inaccessibleEntries >= 2)
        let issues = try ScanResultStore(reference: try unwrap(report.coverage.issueStore)).page()
        checkTrue(issues.items.contains { $0.path == unreadable.path && $0.category.contains("拒绝") })
        checkTrue(issues.items.contains { $0.path == denied.deletingLastPathComponent().path })
        checkTrue(issues.items.allSatisfy { !$0.canTrash })
    } else { print("SKIP access-denied assertion: fixture runs as root") }
    let foundLarge = try rows(report.largeFiles)
    checkTrue(foundLarge.contains { $0.path == large.path && $0.canTrash })
    checkTrue(foundLarge.contains { $0.path == old.path && $0.category.contains("旧文件") && $0.canTrash })
    checkTrue(foundLarge.contains { $0.path == app.path && !$0.canTrash })
    checkFalse(foundLarge.contains { $0.path == ignored.path || $0.path == "/" || $0.path == home.path })
    let duplicateRows = try rows(report.duplicates)
    let expectedDigest = SHA256.hash(data: Data(repeating: 0x41, count: 64)).map { String(format: "%02x", $0) }.joined()
    let group = duplicateRows.filter { $0.group == expectedDigest }
    checkEqual(group.count, geteuid() == 0 ? 7 : 5)
    checkEqual(group.filter { $0.category == "保留原件" }.count, 1)
    checkTrue(group.contains { $0.path == b.path }); checkTrue(group.contains { $0.path == c.path }); checkTrue(group.contains { $0.path == d.path })
    checkTrue(group.contains { $0.path == app.path && !$0.canTrash })
    checkTrue(group.allSatisfy { $0.retainedPath == group.first?.retainedPath && $0.retainedIdentity == group.first?.retainedIdentity })
    let keeper = try unwrap(group.first { $0.category == "保留原件" })
    checkFalse(keeper.canTrash); checkEqual(keeper.identity, keeper.retainedIdentity)
    checkFalse(group.contains { $0.path == ignored.path || $0.path == outside.path || $0.path == unreadable.path } && geteuid() != 0)
    checkTrue(report.largeFiles.stopReason == nil && report.duplicates.stopReason == nil) // Permission errors continue the other roots.

    // Overlapping roots are deduplicated by inode on disk, without a global Set.
    let overlap = fixture.appendingPathComponent("overlap")
    try file(overlap.appendingPathComponent("one"), bytes: 3)
    try file(overlap.appendingPathComponent("sub/two"), bytes: 7)
    let once = scan(.init(roots: [overlap]), home: home)
    let overlapping = scan(.init(roots: [overlap, overlap.appendingPathComponent("sub"), overlap]), home: home)
    checkEqual(overlapping.coverage.regularFiles, 2); checkEqual(overlapping.coverage.logicalBytes, 10)
    checkEqual(overlapping.coverage.visitedEntries, once.coverage.visitedEntries)

    // Parent policy exclusions apply to that parent root, not to a separately
    // listed data root. A nested excluded mount remains excluded within it.
    let mounts = fixture.appendingPathComponent("volumes"), disk = mounts.appendingPathComponent("DataDisk")
    let remote = disk.appendingPathComponent("RemoteMount"), policyHome = fixture.appendingPathComponent("policy-home")
    try fm.createDirectory(at: policyHome, withIntermediateDirectories: true)
    let local = try file(disk.appendingPathComponent("local"), bytes: 31)
    try file(remote.appendingPathComponent("remote"), bytes: 99)
    let mountPlan = FullDiskScanPlan(roots: [mounts, disk], excludedPaths: [mounts.path, disk.path, remote.path])
    let volumeReport = scan(mountPlan, home: policyHome, threshold: 1)
    checkFalse(volumeReport.coverage.incomplete); checkEqual(volumeReport.coverage.regularFiles, 1)
    let volumeRows = try rows(volumeReport.largeFiles)
    checkTrue(volumeRows.contains { $0.path == local.path })
    try IgnoreRuleStore(home: policyHome).save([disk.path])
    let userExcluded = scan(mountPlan, home: policyHome, threshold: 1)
    checkEqual(userExcluded.coverage.regularFiles, 0); checkEqual(userExcluded.largeFiles.totalItemCount, 0)
    let config = IgnoreRuleStore(home: policyHome).fileURL
    try Data("broken configuration".utf8).write(to: config)
    let closed = scan(mountPlan, home: policyHome)
    checkEqual(closed.coverage.visitedEntries, 0); checkTrue(closed.coverage.incomplete)
    checkEqual(closed.largeFiles.stopReason, .configurationError)

    // Pure APFS injection: no test traverses the real startup or Data roots.
    checkEqual(FullDiskVolumePolicy.allowedDevices(rootPath: "/", rootDevice: 1, startupDataDevice: 2, startupDataIsLocal: true), [1, 2])
    checkEqual(FullDiskVolumePolicy.allowedDevices(rootPath: "/", rootDevice: 1, startupDataDevice: 1, startupDataIsLocal: true), [1])
    checkEqual(FullDiskVolumePolicy.allowedDevices(rootPath: "/", rootDevice: 1, startupDataDevice: 2, startupDataIsLocal: false), [1])
    checkEqual(FullDiskVolumePolicy.allowedDevices(rootPath: disk.path, rootDevice: 1, startupDataDevice: 2, startupDataIsLocal: true), [1])
    checkFalse(FullDiskVolumePolicy.allowedDevices(rootPath: "/", rootDevice: 1, startupDataDevice: 2, startupDataIsLocal: true).contains(3))
    let managed = "/generated/tmp/AIYOUClean-results-" + UUID().uuidString
    checkTrue(FullDiskPathPolicy.isManagedIndex(path: managed + "/results.sqlite3", temporaryBase: "/generated/tmp"))
    checkFalse(FullDiskPathPolicy.isManagedIndex(path: "/personal/" + String(managed.dropFirst()), temporaryBase: "/generated/tmp"))
    checkFalse(FullDiskPathPolicy.isManagedIndex(path: "/generated/tmp/user-project/AIYOUClean-results-" + UUID().uuidString, temporaryBase: "/generated/tmp"))

    // Search permission on an ancestor is sufficient to reach an explicitly
    // selected readable child; a rejected alias must not poison inode dedup.
    let searchParent = fixture.appendingPathComponent("search-only-parent")
    let searchChild = searchParent.appendingPathComponent("readable-child")
    try file(searchChild.appendingPathComponent("readable.dat"), bytes: 9)
    try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: searchParent.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: searchParent.path) }
    let searchOnly = scan(.init(roots: [searchChild]), home: home)
    checkFalse(searchOnly.coverage.incomplete); checkEqual(searchOnly.coverage.regularFiles, 1)
    let actualParent = fixture.appendingPathComponent("actual-parent")
    let actualChild = actualParent.appendingPathComponent("child")
    try file(actualChild.appendingPathComponent("once.dat"), bytes: 11)
    let alias = fixture.appendingPathComponent("alias-parent")
    try fm.createSymbolicLink(at: alias, withDestinationURL: actualParent)
    let aliasThenReal = scan(.init(roots: [alias.appendingPathComponent("child"), actualChild]), home: home)
    checkEqual(aliasThenReal.coverage.regularFiles, 1)
    checkTrue(aliasThenReal.coverage.incomplete)

    // More than one disk page, and cancellation of traversal as well as hashing.
    let many = home.appendingPathComponent("Many")
    for index in 0..<260 { _ = try autoreleasepool { try file(many.appendingPathComponent(String(format: "%04d", index)), bytes: 3, value: 0x33) } }
    let manyPlan = FullDiskScopePlanner.selectedFolders([many], home: home)
    let manyReport = scan(manyPlan, home: home, threshold: 1)
    checkFalse(manyReport.coverage.incomplete)
    checkEqual(manyReport.largeFiles.items.count, 200); checkEqual(manyReport.largeFiles.totalItemCount, 260)
    checkEqual(manyReport.duplicates.items.count, 200); checkEqual(manyReport.duplicates.totalItemCount, 260)
    let finalPage = try ScanResultStore(reference: try unwrap(manyReport.duplicates.resultStore)).page(offset: 200)
    checkEqual(finalPage.items.count, 60); checkEqual(finalPage.filteredCount, 260)
    var allRows = 0
    try ScanResultStore(reference: try unwrap(manyReport.duplicates.resultStore)).forEachItem { _ in allRows += 1 }
    checkEqual(allRows, 260)
    let cancelWalk = MalwareCancellation()
    let cancelled = scan(manyPlan, home: home, threshold: 1, cancellation: cancelWalk, progress: { _, _ in cancelWalk.cancel() })
    checkTrue(cancelled.coverage.cancelled); checkTrue(cancelled.coverage.incomplete)
    checkTrue(cancelled.coverage.regularFiles < 260); checkEqual(cancelled.largeFiles.stopReason, .cancelled)
    let cancelHash = MalwareCancellation()
    let hashCancelled = scan(manyPlan, home: home, threshold: 1, cancellation: cancelHash,
                             progress: { _, path in if path.hasPrefix("SHA-256") { cancelHash.cancel() } })
    checkTrue(hashCancelled.coverage.cancelled); checkEqual(hashCancelled.coverage.regularFiles, 260)
    checkEqual(hashCancelled.duplicates.stopReason, .cancelled)
    let lease = try unwrap(WorkBudget.tryAcquire("full disk check busy fixture"))
    let busy = scan(manyPlan, home: home)
    lease.release(); checkEqual(busy.largeFiles.stopReason, .busy); checkEqual(busy.coverage.visitedEntries, 0)
    print("PASS full-disk file fixtures: selected personal roots, cross-root SHA groups, old/large and package readonly, access errors/ignore/link coverage, disk pages/cancel, scoped mounts and APFS device policy")
}
