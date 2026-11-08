import Foundation
import Darwin
import CleanRoomCore

func runMetadataTreeChecks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtureRoot = project.appendingPathComponent(".test-fixtures/metadata-tree-" + UUID().uuidString)
    try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixtureRoot) }
    @discardableResult func directory(_ relative: String) throws -> URL {
        let url = fixtureRoot.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @discardableResult func file(_ relative: String, bytes: Int) throws -> URL {
        let url = fixtureRoot.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url); return url
    }
    func summarize(_ root: URL, excluded: [String] = [], depth: Int = 128) -> MetadataTreeSummary {
        MetadataTreeWalker.summarize(root: root, excludedPaths: excluded, maxDepth: depth, shouldStop: { false }, onVisit: { _ in })
    }
    let plain = try file("plain.dat", bytes: 37)
    var rootFileVisits = 0
    let rootFile = MetadataTreeWalker.summarize(root: plain, shouldStop: { false }, onVisit: { _ in rootFileVisits += 1 })
    checkEqual(rootFile.logicalBytes, 37); checkEqual(rootFile.visitedEntries, 0); checkEqual(rootFileVisits, 0)
    checkTrue(rootFile.complete); checkFalse(rootFile.unsafeToTrash)
    let empty = try directory("empty")
    let emptyResult = summarize(empty)
    checkTrue(emptyResult.complete); checkEqual(emptyResult.visitedEntries, 0); checkEqual(emptyResult.logicalBytes, 0)
    try file("Bundle/Fake.app/Contents/MacOS/Fake", bytes: 13)
    try file("Bundle/Fake.app/Contents/Frameworks/Nested.framework/Versions/A/binary", bytes: 29)
    try file("Bundle/Fake.app/Contents/Resources/资源.dat", bytes: 17)
    let bundleRoot = fixtureRoot.appendingPathComponent("Bundle")
    var bundleVisits = 0
    let bundle = MetadataTreeWalker.summarize(root: bundleRoot, shouldStop: { false }, onVisit: { _ in bundleVisits += 1 })
    checkEqual(bundle.logicalBytes, 59); checkTrue(bundle.complete); checkFalse(bundle.unsafeToTrash)
    checkEqual(bundle.visitedEntries, bundleVisits); checkTrue(bundle.visitedEntries > 3)
    let outside = try file("outside/keep", bytes: 1000), links = try directory("links")
    try file("links/local", bytes: 5)
    try fm.createSymbolicLink(at: links.appendingPathComponent("outside-file"), withDestinationURL: outside)
    try fm.createSymbolicLink(at: links.appendingPathComponent("outside-directory"), withDestinationURL: outside.deletingLastPathComponent())
    let linked = summarize(links)
    checkEqual(linked.logicalBytes, 5); checkEqual(linked.skippedEntries, 2); checkTrue(linked.complete); checkTrue(linked.unsafeToTrash)
    let rootLink = summarize(links.appendingPathComponent("outside-directory"))
    checkEqual(rootLink.logicalBytes, 0); checkTrue(rootLink.unsafeToTrash); checkEqual(rootLink.visitedEntries, 0)
    let ancestorLink = summarize(links.appendingPathComponent("outside-directory/keep"))
    checkEqual(ancestorLink.logicalBytes, 0); checkTrue(ancestorLink.unsafeToTrash)
    let ignoreRoot = try directory("ignored")
    try file("ignored/skip/secret", bytes: 333)
    try file("ignored/skip-sibling/visible", bytes: 19)
    try file("ignored/normal", bytes: 7)
    var names: [String] = []
    let ignoredPath = ignoreRoot.appendingPathComponent("skip").path
    let ignored = MetadataTreeWalker.summarize(root: ignoreRoot, excludedPaths: [ignoredPath], shouldStop: { false }, onVisit: { names.append($0) })
    checkEqual(ignored.logicalBytes, 26); checkTrue(ignored.complete); checkTrue(ignored.unsafeToTrash)
    checkFalse(names.contains { $0.hasPrefix(ignoredPath + "/") })
    checkTrue(names.contains { $0.contains("skip-sibling/visible") })
    let futureIgnored = summarize(ignoreRoot, excluded: [ignoreRoot.appendingPathComponent("future/missing").path])
    checkEqual(futureIgnored.logicalBytes, 359); checkTrue(futureIgnored.complete); checkTrue(futureIgnored.unsafeToTrash)
    let ignoredRoot = summarize(ignoreRoot, excluded: [ignoreRoot.path])
    checkEqual(ignoredRoot.logicalBytes, 0); checkEqual(ignoredRoot.visitedEntries, 0); checkTrue(ignoredRoot.unsafeToTrash)
    let hard = try file("hardlinks/original", bytes: 23)
    try fm.linkItem(at: hard, to: hard.deletingLastPathComponent().appendingPathComponent("second-name"))
    checkEqual(summarize(hard.deletingLastPathComponent()).logicalBytes, 46) // Logical per-path semantics, not savings.
    let policy = try directory("policy")
    for name in [".git", ".Trash", ".DocumentRevisions-V100", ".Spotlight-V100", ".fseventsd"] { try file("policy/\(name)/nested/ignored", bytes: 100) }
    try file("policy/normal", bytes: 11)
    let policyResult = summarize(policy)
    checkEqual(policyResult.logicalBytes, 11); checkEqual(policyResult.skippedEntries, 5)
    checkTrue(policyResult.complete); checkTrue(policyResult.unsafeToTrash); checkLessThan(policyResult.warnings.count, 3)
    let fifo = fixtureRoot.appendingPathComponent("generated-fifo")
    checkEqual(mkfifo(fifo.path, 0o600), 0)
    let special = summarize(fifo)
    checkEqual(special.logicalBytes, 0); checkTrue(special.complete); checkTrue(special.unsafeToTrash)
    let thousands = try directory("thousands")
    var expectedBytes: Int64 = 0
    for index in 0..<3000 {
        let count = index % 23 + 1
        try autoreleasepool { _ = try file("thousands/group-\(index / 200)/file-\(index)", bytes: count) }
        expectedBytes += Int64(count)
    }
    var exactCount = 0
    let many = MetadataTreeWalker.summarize(root: thousands, shouldStop: { false }, onVisit: { _ in exactCount += 1 })
    checkEqual(many.logicalBytes, expectedBytes); checkEqual(many.visitedEntries, 3015); checkEqual(exactCount, 3015)
    checkTrue(many.complete); checkFalse(many.unsafeToTrash)
    var budgetCount = 0
    let budget = MetadataTreeWalker.summarize(root: thousands, shouldStop: { budgetCount >= 40 }, onVisit: { _ in budgetCount += 1 })
    checkEqual(budget.visitedEntries, 40); checkFalse(budget.complete); checkTrue(budget.unsafeToTrash)
    checkTrue(budget.logicalBytes <= expectedBytes)
    var cancelledVisits = 0
    let cancelled = MetadataTreeWalker.summarize(root: thousands, shouldStop: { true }, onVisit: { _ in cancelledVisits += 1 })
    checkEqual(cancelled.visitedEntries, 0); checkEqual(cancelledVisits, 0); checkFalse(cancelled.complete)
    let deepRoot = try directory("deep")
    var deepest = deepRoot
    for _ in 0..<150 { deepest.appendPathComponent("d"); try fm.createDirectory(at: deepest, withIntermediateDirectories: false) }
    try Data([1, 2, 3]).write(to: deepest.appendingPathComponent("end"))
    let deeplyNested = summarize(deepRoot)
    checkTrue(deeplyNested.complete); checkFalse(deeplyNested.unsafeToTrash); checkEqual(deeplyNested.logicalBytes, 3)
    checkEqual(deeplyNested.visitedEntries, 151); checkEqual(deeplyNested.skippedEntries, 0); checkTrue(deeplyNested.warnings.isEmpty)
    let smallDepth = summarize(bundleRoot, depth: 2)
    checkTrue(smallDepth.complete); checkFalse(smallDepth.unsafeToTrash); checkEqual(smallDepth.logicalBytes, 59)
    checkEqual(smallDepth.visitedEntries, bundle.visitedEntries)
    let singleDescriptorDepth = summarize(deepRoot, depth: 1)
    checkTrue(singleDescriptorDepth.complete); checkFalse(singleDescriptorDepth.unsafeToTrash)
    checkEqual(singleDescriptorDepth.logicalBytes, 3); checkEqual(singleDescriptorDepth.visitedEntries, 151)
    var deferredVisits = 0
    let deferredCancellation = MetadataTreeWalker.summarize(root: deepRoot, shouldStop: { deferredVisits >= 130 }, onVisit: { _ in deferredVisits += 1 })
    checkEqual(deferredCancellation.visitedEntries, 130); checkEqual(deferredVisits, 130)
    checkEqual(deferredCancellation.logicalBytes, 0); checkFalse(deferredCancellation.complete); checkTrue(deferredCancellation.unsafeToTrash)
    checkFalse(summarize(bundleRoot, depth: 0).complete)
    let nonexistent = summarize(fixtureRoot.appendingPathComponent("does-not-exist"))
    checkFalse(nonexistent.complete); checkTrue(nonexistent.unsafeToTrash); checkFalse(nonexistent.warnings.isEmpty)
    let notFileURL = summarize(URL(string: "https://example.invalid/not-a-local-root")!)
    checkFalse(notFileURL.complete)
    let invalidRule = summarize(thousands, excluded: ["not-absolute"])
    checkFalse(invalidRule.complete); checkEqual(invalidRule.visitedEntries, 0)
    let denied = try directory("denied"), deniedFile = try file("denied/unreadable", bytes: 99)
    checkEqual(chmod(denied.path, 0), 0)
    defer { _ = chmod(denied.path, 0o700) }
    let permissions = summarize(denied)
    if geteuid() == 0 { print("SKIP metadata permission-denied assertion: root bypasses fixture permissions") }
    else { checkFalse(permissions.complete); checkTrue(permissions.unsafeToTrash); checkFalse(permissions.warnings.isEmpty) }
    let ignoredPermissions = summarize(fixtureRoot, excluded: [denied.path])
    checkFalse(ignoredPermissions.warnings.contains { $0.contains(deniedFile.path) })
    _ = chmod(denied.path, 0o700)
    // Swapping a selected descendant to an external symlink from a progress
    // callback cannot cause content or metadata traversal through that symlink.
    let raceRoot = try directory("race"), originalDirectory = try directory("race/child")
    try file("race/child/original", bytes: 1)
    var swapped = false
    let raced = MetadataTreeWalker.summarize(root: raceRoot, shouldStop: { false }, onVisit: { path in
        if path == originalDirectory.path && !swapped {
            swapped = true
            try? fm.moveItem(at: originalDirectory, to: fixtureRoot.appendingPathComponent("moved-generated-child"))
            try? fm.createSymbolicLink(at: originalDirectory, withDestinationURL: outside.deletingLastPathComponent())
        }
    })
    checkTrue(swapped); checkEqual(raced.logicalBytes, 0); checkTrue(raced.unsafeToTrash)
    checkTrue(fm.fileExists(atPath: outside.path))
    // At depth=2 the nested child is queued rather than held open recursively.
    // Its replacement changes the inner parent, leaving the selected root's
    // identity and timestamps intact; the no-follow reopen still rejects it.
    // Replacing it after its metadata was read cannot redirect the reopen.
    let queuedRaceRoot = try directory("queued-race"), queuedOriginal = try directory("queued-race/outer/child")
    try file("queued-race/outer/child/original", bytes: 1)
    var queuedVisits = 0, queueSwapped = false
    let queuedRace = MetadataTreeWalker.summarize(root: queuedRaceRoot, maxDepth: 2, shouldStop: {
        if queuedVisits == 2 && !queueSwapped {
            queueSwapped = true
            try? fm.moveItem(at: queuedOriginal, to: fixtureRoot.appendingPathComponent("moved-queued-generated-child"))
            try? fm.createSymbolicLink(at: queuedOriginal, withDestinationURL: outside.deletingLastPathComponent())
        }
        return false
    }, onVisit: { _ in queuedVisits += 1 })
    checkTrue(queueSwapped); checkEqual(queuedRace.visitedEntries, 2); checkEqual(queuedRace.logicalBytes, 0)
    checkFalse(queuedRace.complete); checkTrue(queuedRace.unsafeToTrash); checkTrue(fm.fileExists(atPath: outside.path))
    print("PASS POSIX metadata tree: bundles, policy skips, boundaries, 3000 files, 150-level disk queue, cancellation, permissions")
}
