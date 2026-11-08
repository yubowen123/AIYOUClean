import Foundation
import Darwin
@testable import CleanRoomCore

func runExtendedChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = project.appendingPathComponent(".test-fixtures/extended-" + UUID().uuidString), home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    @discardableResult func file(_ relative: String, _ text: String = "fixture") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
    var references: [ScanResultReference] = []
    defer { for reference in references { try? ScanResultStore.remove(reference) } }
    func cleanup(_ category: ExtendedCleanupCategory, options: ExtendedCleanupOptions, cancellation: MalwareCancellation = MalwareCancellation()) -> ExtendedCleanupReport {
        let report = ExtendedCleanupScanner().scan(category, options: options, cancellation: cancellation)
        if let reference = report.resultStore { references.append(reference) }
        return report
    }
    let options = ExtendedCleanupOptions(home: home)
    let corrupt = try file("Library/Preferences/broken.plist", "this is not a plist")
    let valid = home.appendingPathComponent("Library/Preferences/valid.plist")
    try PropertyListSerialization.data(fromPropertyList: ["setting":true], format: .binary, options: 0).write(to: valid)
    let preferences = cleanup(.brokenPreferences, options: options)
    checkEqual(preferences.items.count, 1); checkEqual(preferences.items.first?.path, corrupt.path)
    checkTrue(preferences.items.first?.canTrash == true); checkTrue(fm.fileExists(atPath: valid.path))
    let npm = try file(".npm/_cacache/content/one", "cached bytes")
    try file("Library/Developer/Xcode/DerivedData/Fixture/Build/generated", "build bytes")
    let developer = cleanup(.developerCaches, options: options)
    checkTrue(developer.items.contains { $0.path.contains(".npm/_cacache/content") && $0.bytes == 12 })
    checkTrue(developer.items.contains { $0.path.contains("DerivedData/Fixture") })
    checkTrue(fm.fileExists(atPath: npm.path))
    try file(".cache/huggingface/hub/model/sample", "model")
    checkTrue(cleanup(.aiCaches, options: options).items.contains { $0.detail.contains("重新下载") })
    try file("Library/Application Support/MobileSync/Backup/device/Info.plist", "backup fixture")
    checkTrue(cleanup(.iOSBackups, options: options).items.contains { $0.detail.contains("完整备份") })
    let token = MalwareCancellation(); token.cancel()
    checkTrue(cleanup(.developerCaches, options: options, cancellation: token).cancelled)
    let clipped = cleanup(.developerCaches, options: ExtendedCleanupOptions(home: home, maxFiles: 1, scanToCompletion: false))
    checkTrue(clipped.truncated); checkTrue(clipped.items.allSatisfy { !$0.canTrash })
    let capped = cleanup(.developerCaches, options: ExtendedCleanupOptions(home: home, maxResults: 1))
    checkEqual(capped.items.count, 1); checkFalse(capped.truncated); checkTrue(capped.totalCount > 1)
    let fixtureTrash = home.appendingPathComponent("fixture-trash")
    try fm.createDirectory(at: fixtureTrash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let first = fixtureTrash.appendingPathComponent("one.txt"); try Data("delete generated fixture".utf8).write(to: first)
    let inspector = TrashInspector(testRoots: [fixtureTrash], home: home)
    func inspect(options: ExtendedCleanupOptions, cancellation: MalwareCancellation = MalwareCancellation()) -> TrashInspectionReport {
        let report = inspector.scan(options: options, cancellation: cancellation)
        if let reference = report.resultStore { references.append(reference) }
        return report
    }
    let firstReport = inspect(options: options), firstItem = try unwrap(firstReport.items.first)
    checkTrue(firstItem.canPermanentlyDelete)
    checkFalse(inspector.permanentlyDelete([firstItem], confirmed: false, confirmationPaths: [first.path]).errors.isEmpty)
    checkFalse(inspector.permanentlyDelete([firstItem], confirmed: true, confirmationPaths: []).errors.isEmpty)
    checkTrue(fm.fileExists(atPath: first.path))
    try Data("changed fixture".utf8).write(to: first)
    checkFalse(inspector.permanentlyDelete([firstItem], confirmed: true, confirmationPaths: [first.path]).errors.isEmpty)
    let current = try unwrap(inspect(options: options).items.first)
    let deleted = inspector.permanentlyDelete([current], confirmed: true, confirmationPaths: [first.path])
    checkEqual(deleted.deletedPaths, [first.path]); checkTrue(deleted.errors.isEmpty); checkFalse(fm.fileExists(atPath: first.path))
    checkTrue(fm.fileExists(atPath: fixtureTrash.path)) // Never removes the trash root itself.
    let nested = fixtureTrash.appendingPathComponent("directory/sub/nested.txt")
    try fm.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: nested)
    let directoryItem = try unwrap(inspect(options: options).items.first)
    try Data("new nested contents".utf8).write(to: nested)
    checkFalse(inspector.permanentlyDelete([directoryItem], confirmed: true, confirmationPaths: [directoryItem.path]).errors.isEmpty)
    checkTrue(fm.fileExists(atPath: nested.path))
    let refreshed = try unwrap(inspect(options: options).items.first)
    checkEqual(inspector.permanentlyDelete([refreshed], confirmed: true, confirmationPaths: [refreshed.path]).deletedPaths.count, 1)
    checkFalse(fm.fileExists(atPath: nested.path))
    let outside = try file("keep.txt", "outside trash")
    let linkedDirectory = fixtureTrash.appendingPathComponent("with-link")
    try fm.createDirectory(at: linkedDirectory, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: linkedDirectory.appendingPathComponent("link"), withDestinationURL: outside)
    let unsafe = try unwrap(inspect(options: options).items.first)
    checkFalse(unsafe.canPermanentlyDelete)
    checkFalse(inspector.permanentlyDelete([unsafe], confirmed: true, confirmationPaths: [unsafe.path]).errors.isEmpty)
    checkTrue(fm.fileExists(atPath: outside.path))
    let noPermission = inspector.permanentlyDelete([unsafe], confirmed: true, confirmationPaths: [unsafe.path], cancellation: token)
    checkTrue(noPermission.cancelled); checkTrue(noPermission.deletedPaths.isEmpty)
    if let lease = WorkBudget.tryAcquire("generated test concurrency") {
        checkTrue(cleanup(.developerCaches, options: options).truncated)
        checkTrue(inspect(options: options).truncated)
        lease.release()
    }
    try runExtendedScaleChecks()
    // System API integration operates only on this generated document. A volume
    // without version support is reported as a skip rather than a fabricated pass.
    let document = try file("versioned-fixture.txt", "CURRENT DOCUMENT")
    let old = try file("old-version.txt", "OLD HISTORY")
    do {
        _ = try NSFileVersion.addOfItem(at: document, withContentsOf: old, options: [])
    } catch {
        print("SKIP NSFileVersion integration: generated fixture volume does not support version creation: \(error.localizedDescription)")
        print("PASS extended cleanup candidates and generated-trash safety checks")
        return
    }
    let archive = DocumentVersionArchive(root: root.appendingPathComponent("archive"))
    let firstSelection = try unwrap(try archive.list(document: document).first)
    let version = try unwrap(try archive.list(document: document).first)
    checkThrows(try { _ = try archive.archiveAndRemove(firstSelection, confirmed: true) }()) // Refresh invalidates stale opaque IDs.
    let roundTrip = try JSONDecoder().decode(DocumentHistoryVersion.self, from: JSONEncoder().encode(version))
    checkEqual(roundTrip.identifierData.count, 36)
    checkThrows(try { _ = try archive.archiveAndRemove(version, confirmed: false) }())
    let receipt = try archive.archiveAndRemove(version, confirmed: true)
    checkTrue(receipt.versionRemoved); checkEqual(try String(contentsOf: document, encoding: .utf8), "CURRENT DOCUMENT")
    checkEqual(try String(contentsOfFile: receipt.backupPath, encoding: .utf8), "OLD HISTORY")
    checkThrows(try archive.restoreAsVersion(receipt, confirmed: false))
    try archive.restoreAsVersion(receipt, confirmed: true)
    checkEqual(try String(contentsOf: document, encoding: .utf8), "CURRENT DOCUMENT")
    let restoredRecords = try archive.records()
    checkTrue(restoredRecords.contains { $0.id == receipt.id && $0.restoredAsHistory })
    print("PASS extended cleanup, generated-trash boundaries, and NSFileVersion archive/restore")
}
