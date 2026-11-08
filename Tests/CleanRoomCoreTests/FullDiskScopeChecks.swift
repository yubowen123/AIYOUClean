import Foundation
@testable import CleanRoomCore

func runFullDiskScopeChecks() throws {
    func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
    let home = url("/generated-full-disk-fixture/Users/current")
    let otherHome = url("/generated-full-disk-fixture/Users/another")
    // Pure injected metadata only: these URLs are never listed or opened.
    let mounts: [FullDiskVolumeMetadata] = [
        .init(root: url("/"), isReadOnly: true, isHidden: true, isSnapshot: true, isRootFileSystem: true),
        .init(root: url("/System/Volumes/Data")),
        .init(root: url("/System/Volumes/Preboot"), isHidden: true),
        .init(root: url("/System/Volumes/VM"), isHidden: true),
        .init(root: url("/Volumes/External"), fileSystemType: "exfat"),
        .init(root: url("/Volumes/External"), fileSystemType: "exfat"), // repeated metadata
        .init(root: url("/Volumes/External/NestedLocal")),
        .init(root: url("/Volumes/External/Remote"), fileSystemType: "smbfs", isLocal: false),
        .init(root: url("/Volumes/ReadOnly"), fileSystemType: "hfs", isReadOnly: true),
        .init(root: url("/Volumes/Preboot")), // an ordinary, browsable data disk
        .init(root: url("/Volumes/VM")),
        .init(root: url("/Volumes/HiddenHelper"), isHidden: true),
        .init(root: url("/Volumes/BackupSnapshot"), isReadOnly: true, isSnapshot: true),
        .init(root: url("/Volumes/Network"), fileSystemType: "smbfs", isLocal: false),
        .init(root: url("/generated-full-disk-fixture/RemoteMount"), fileSystemType: "nfs", isLocal: false),
        .init(root: url("/dev"), fileSystemType: "devfs"),
        .init(root: url("/generated-full-disk-fixture/Virtual"), fileSystemType: "devfs"),
        .init(root: url("/generated-full-disk-fixture/LocalMount"), fileSystemType: "ntfs", isReadOnly: true),
        .init(root: URL(string: "https://example.invalid/not-a-mount")!)
    ]
    let cache = home.appendingPathComponent("Library/Caches")
    let logs = home.appendingPathComponent("Library/Logs")
    let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let otherCache = otherHome.appendingPathComponent("Library/Caches")
    let systemCache = url("/Library/Caches")
    let plan = FullDiskScopePlanner.localDisks(volumes: mounts, home: home, existingCleanupDirectories: [cache, logs, derived, otherCache, systemCache, home, url("/"), url("/Library"), home.appendingPathComponent("Downloads"), url("/unregistered-user/Library/Caches")], additionalHomes: [otherHome])
    let roots = plan.roots.map(\.path)
    checkEqual(roots.first, "/")
    checkEqual(roots.count, 8)
    checkEqual(Set(roots).count, roots.count)
    for included in ["/Volumes/External", "/Volumes/External/NestedLocal", "/Volumes/ReadOnly", "/Volumes/Preboot", "/Volumes/VM", "/Volumes/HiddenHelper", "/generated-full-disk-fixture/LocalMount"] { checkTrue(roots.contains(included)) }
    for absent in ["/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM", "/Volumes/BackupSnapshot", "/Volumes/Network", "/dev", "/generated-full-disk-fixture/Virtual", "/generated-full-disk-fixture/RemoteMount"] { checkFalse(roots.contains(absent)) }
    for excluded in ["/dev", "/Network", "/System/Volumes", "/Volumes", "/Volumes/External/NestedLocal", "/Volumes/External/Remote", "/generated-full-disk-fixture/RemoteMount", "/generated-full-disk-fixture/LocalMount"] { checkTrue(plan.excludedPaths.contains(excluded)) }
    // /private is reached through logical /; never hide it as a root alias.
    checkFalse(plan.excludedPaths.contains("/private"))
    checkFalse(plan.excludedPaths.contains("/Users"))
    checkFalse(plan.excludedPaths.contains("/"))
    checkEqual(Set(plan.cleanupRoots.map(\.path)), Set([cache.path, logs.path, derived.path, otherCache.path, systemCache.path]))
    checkFalse(plan.cleanupRoots.contains { $0.path == "/" || $0.path == home.path || $0.path == "/Library" })
    checkTrue(plan.notes.contains { $0.contains("只读") })
    checkTrue(plan.notes.contains { $0.contains("未访问") })
    checkFalse(plan.notes.contains { $0.contains("保证全覆盖") })

    let missingHome = FullDiskScopePlanner.localDisks(volumes: [], home: url("/generated-full-disk-fixture/missing-home"), existingCleanupDirectories: [])
    checkEqual(missingHome.roots.map(\.path), ["/"])
    checkTrue(missingHome.cleanupRoots.isEmpty)
    checkEqual(Set(missingHome.excludedPaths), Set(["/dev", "/Network", "/System/Volumes", "/Volumes"]))
    let invalidHome = FullDiskScopePlanner.localDisks(volumes: [], home: URL(string: "https://example.invalid/home")!, existingCleanupDirectories: [url("/Library/Caches"), url("/Library")])
    checkEqual(invalidHome.cleanupRoots.map(\.path), ["/Library/Caches"])
    checkTrue(invalidHome.notes.contains { $0.contains("用户目录参数无效") })

    let selected = FullDiskScopePlanner.selectedFolders([url("/generated-full-disk-fixture/a/nested"), url("/generated-full-disk-fixture/a"), url("/generated-full-disk-fixture/a/../a"), url("/generated-full-disk-fixture/a-sibling"), URL(string: "https://example.invalid/folder")!], home: home)
    checkEqual(Set(selected.roots.map(\.path)), Set(["/generated-full-disk-fixture/a", "/generated-full-disk-fixture/a/nested", "/generated-full-disk-fixture/a-sibling"]))
    checkTrue(selected.excludedPaths.isEmpty); checkTrue(selected.cleanupRoots.isEmpty)
    checkFalse(selected.roots.contains { $0.path == "/" })
    let explicitDisk = FullDiskScopePlanner.selectedFolders([url("/Volumes/External/folder"), url("/Volumes/External"), url("/Volumes/External-two")], home: home)
    checkEqual(Set(explicitDisk.roots.map(\.path)), Set(["/Volumes/External", "/Volumes/External/folder", "/Volumes/External-two"]))
    checkTrue(explicitDisk.excludedPaths.isEmpty)
    let literal = FullDiskScopePlanner.selectedFolders([url("/private/var/generated-full-scope"), URL(string: "file://remote.invalid/should-not-be-local")!], home: home)
    checkEqual(literal.roots.map(\.path), ["/private/var/generated-full-scope"])
    let emptySelected = FullDiskScopePlanner.selectedFolders([], home: home)
    checkTrue(emptySelected.roots.isEmpty); checkTrue(emptySelected.cleanupRoots.isEmpty)
    let explicitRoot = FullDiskScopePlanner.selectedFolders([url("/"), url("/generated-full-disk-fixture/a")], home: home)
    checkEqual(explicitRoot.roots.map(\.path), ["/", "/generated-full-disk-fixture/a"])
    let custom = FullDiskScanPlan(roots: [home])
    checkTrue(custom.excludedPaths.isEmpty); checkTrue(custom.cleanupRoots.isEmpty); checkTrue(custom.notes.isEmpty)
    print("PASS full-disk scope: pure mount metadata, read-only/local data, auxiliary/network/snapshots, safe cleanup parents, explicit folder boundaries")
}
