import Foundation
import Darwin

/// A scope proposal, not a claim that every selected file can be read. Mount
/// exclusions apply while walking the startup root; explicitly listed volume
/// roots must be entered separately. User ignore rules still apply everywhere.
public struct FullDiskScanPlan: Sendable {
    public let roots: [URL]
    public let excludedPaths: [String]
    /// Known cache/log/DerivedData parents only, never a disk or a whole home.
    public let cleanupRoots: [URL]
    public let notes: [String]
    public init(roots: [URL], excludedPaths: [String] = [], cleanupRoots: [URL] = [], notes: [String] = []) {
        self.roots = roots; self.excludedPaths = excludedPaths; self.cleanupRoots = cleanupRoots; self.notes = notes
    }
}

/// Kernel mount metadata, injectable so scope tests never enumerate real disks.
/// A volume's display name is deliberately absent: a data disk named "Preboot"
/// or "VM" must not be confused with a system auxiliary volume.
struct FullDiskVolumeMetadata: Sendable {
    let root: URL
    let fileSystemType: String
    let isLocal: Bool
    let isReadOnly: Bool
    let isHidden: Bool
    let isSnapshot: Bool
    let isRootFileSystem: Bool
    init(root: URL, fileSystemType: String = "apfs", isLocal: Bool = true, isReadOnly: Bool = false, isHidden: Bool = false, isSnapshot: Bool = false, isRootFileSystem: Bool = false) {
        self.root = root; self.fileSystemType = fileSystemType; self.isLocal = isLocal
        self.isReadOnly = isReadOnly; self.isHidden = isHidden; self.isSnapshot = isSnapshot; self.isRootFileSystem = isRootFileSystem
    }
}

public enum FullDiskScopePlanner {
    private static let startupExclusions = ["/dev", "/Network", "/System/Volumes", "/Volumes"]
    private static let virtualFileSystems: Set<String> = ["devfs", "autofs", "fdesc", "volfs", "procfs", "mtmfs", "tmpfs", "ramfs", "rootfs", "nullfs"]
    private static let limitations = "权限、系统保护、忽略规则、云占位内容及符号链接可能留下未访问部分；扫描结果会另行报告，不代表已完整读取所有文件。"

    /// Uses cached kernel mount metadata and shallow known-directory checks.
    /// It never opens source-file contents or traverses a disk to discover scope.
    public static func localDisks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FullDiskScanPlan {
        let mounted = mountedVolumes()
        let otherHomes = realHomesUnderUsers()
        let available = knownCleanupParents(home: home, additionalHomes: otherHomes).filter { existingRealDirectory($0) }
        return localDisks(volumes: mounted.volumes, home: home, existingCleanupDirectories: available, additionalHomes: otherHomes, metadataNotes: mounted.notes)
    }

    /// A user-selected folder remains precisely that scope. Do not discover
    /// other disks or implicitly add the real home when a fixture is supplied.
    public static func selectedFolders(_ roots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FullDiskScanPlan {
        let normalized = normalizedRoots(roots, removeOverlaps: false)
        var notes = ["仅检查明确选择的路径；未额外加入磁盘、用户目录或缓存目录。", limitations]
        if normalized.count < roots.count { notes.append("已去除重复路径和无效的非本地文件URL；明确选择的子目录保留，以覆盖其中的独立挂载卷。") }
        if normalized.isEmpty { notes.append("尚未提供有效的自选路径，未默认扩展到真实磁盘。") }
        // home is intentionally not queried in selected-folder mode.
        _ = home
        return FullDiskScanPlan(roots: normalized, notes: notes)
    }

    /// Pure planning entry point: the caller supplies metadata and existence.
    /// No filesystem calls, account lookups or real-home fallback occur here.
    static func localDisks(volumes: [FullDiskVolumeMetadata], home: URL, existingCleanupDirectories: [URL], additionalHomes: [URL] = [], metadataNotes: [String] = []) -> FullDiskScanPlan {
        var roots = [URL(fileURLWithPath: "/", isDirectory: true)]
        var exclusions = startupExclusions
        var seen = Set(["/"])
        var excludedMounts = 0, readOnlyVolumes = 0
        for volume in volumes {
            guard let root = normalized(volume.root) else { excludedMounts += 1; continue }
            let path = root.path
            // The startup filesystem may itself be a sealed read-only APFS
            // snapshot. It is still the logical entry point to its firmlinks.
            if path == "/" { continue }
            // Exclude every other mount from the startup traversal, including
            // network mounts at custom locations. Local data volumes get their
            // own root below, rather than being visited twice.
            exclusions.append(path)
            let reserved = startupExclusions.contains { contains($0, path) && $0 != "/Volumes" }
            let virtual = virtualFileSystems.contains(volume.fileSystemType.lowercased())
            // nobrowse alone is not an auxiliary-volume role: ordinary local
            // data disks and read-only disk images may use it as well.
            guard volume.isLocal, !virtual, !volume.isSnapshot, !volume.isRootFileSystem, !reserved else {
                excludedMounts += 1; continue
            }
            if seen.insert(path).inserted {
                roots.append(root)
                if volume.isReadOnly { readOnlyVolumes += 1 }
            }
        }
        roots = [roots[0]] + roots.dropFirst().sorted { $0.path < $1.path }
        let allowed = Set(knownCleanupParents(home: home, additionalHomes: additionalHomes).map(\.path))
        let cleanup = normalizedRoots(existingCleanupDirectories.filter { url in normalized(url).map { allowed.contains($0.path) } ?? false }, removeOverlaps: true)
        var notes = ["默认范围为启动磁盘逻辑根目录 /，以及当前已挂载的本地数据卷。", "通过启动卷组的逻辑路径 / 覆盖可访问的 /Users、/Library、/Applications、/private 等数据卷映射；不重复进入 /System/Volumes，/Volumes 内的本地数据卷单独检查。", limitations]
        if excludedMounts > 0 { notes.append("已排除\(excludedMounts)个网络、虚拟、快照或受保护系统辅助挂载卷。") }
        if readOnlyVolumes > 0 { notes.append("包含\(readOnlyVolumes)个只读本地数据卷；进入检查范围不代表可以清理其文件。") }
        notes.append("清理候选仅来自已确认存在的 Caches、Logs 与 Xcode DerivedData 父目录；不会把整块磁盘或整个用户目录当作缓存。")
        if normalized(home) == nil { notes.append("用户目录参数无效，未推断该用户的缓存目录。") }
        notes.append(contentsOf: metadataNotes)
        return FullDiskScanPlan(roots: roots, excludedPaths: normalizedExclusions(exclusions), cleanupRoots: cleanup, notes: notes)
    }

    private static func normalized(_ url: URL) -> URL? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: ScanLexicalPath.normalize(url.path), isDirectory: true)
    }
    private static func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/") }
    private static func normalizedRoots(_ urls: [URL], removeOverlaps: Bool) -> [URL] {
        let sorted = urls.compactMap(normalized).sorted { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }
        var result: [URL] = []
        for url in sorted {
            if result.contains(where: { removeOverlaps ? contains($0.path, url.path) : $0.path == url.path }) { continue }
            result.append(url)
        }
        return result
    }
    private static func normalizedExclusions(_ paths: [String]) -> [String] {
        // Keep nested mount points: /Volumes excludes them from logical /,
        // but an independently entered /Volumes/Data still needs its own
        // nested network or snapshot mount excluded. Only exact duplicates go.
        normalizedRoots(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, removeOverlaps: false).map(\.path).sorted()
    }
    private static func knownCleanupParents(home: URL, additionalHomes: [URL]) -> [URL] {
        var result = ["Caches", "Logs", "Developer/Xcode/DerivedData"].map { URL(fileURLWithPath: "/Library", isDirectory: true).appendingPathComponent($0, isDirectory: true) }
        // Normalize accounts independently: a broad home parameter cannot
        // collapse another account's known cache parent into a whole home.
        for account in normalizedRoots([home] + additionalHomes, removeOverlaps: false) {
            guard account.path != "/" else { continue }
            for suffix in ["Library/Caches", "Library/Logs", "Library/Developer/Xcode/DerivedData"] { result.append(account.appendingPathComponent(suffix, isDirectory: true)) }
        }
        return result
    }
    private static func string<T>(_ tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { bytes in String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) }
    }
    private static func mountedVolumes() -> (volumes: [FullDiskVolumeMetadata], notes: [String]) {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return ([], ["未能取得已挂载卷列表；本次范围只能确认逻辑 /，请检查磁盘连接与权限。"]) }
        defer { free(entries) }
        var result: [FullDiskVolumeMetadata] = []
        var invalid = false
        for index in 0..<Int(count) {
            autoreleasepool {
                let mount = entries[index]
                guard let path = string(mount.f_mntonname), path.hasPrefix("/"), let type = string(mount.f_fstypename) else { invalid = true; return }
                let flags = mount.f_flags
                result.append(FullDiskVolumeMetadata(root: URL(fileURLWithPath: path, isDirectory: true), fileSystemType: type, isLocal: flags & UInt32(MNT_LOCAL) != 0, isReadOnly: flags & UInt32(MNT_RDONLY) != 0, isHidden: flags & UInt32(MNT_DONTBROWSE) != 0, isSnapshot: flags & UInt32(MNT_SNAPSHOT) != 0, isRootFileSystem: flags & UInt32(MNT_ROOTFS) != 0))
            }
        }
        return (result, invalid ? ["部分挂载元数据含无法表达的路径；这些卷未被加入范围。"] : [])
    }
    /// A one-level account inventory, not a filesystem scan. Shared, aliases,
    /// archived folders and symlinked homes do not become cleanup scopes.
    private static func realHomesUnderUsers() -> [URL] {
        let fd = open("/Users", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        guard let directory = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(directory) }
        var result: [URL] = []
        while let entry = readdir(directory) {
            autoreleasepool {
                guard let name = string(entry.pointee.d_name), name != ".", name != ".." else { return }
                var metadata = stat()
                guard fstatat(dirfd(directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return }
                let path = "/Users/" + name
                guard let registered = FileManager.default.homeDirectory(forUser: name), let account = normalized(registered), account.path == path, existingRealDirectory(account) else { return }
                result.append(account)
            }
        }
        return result
    }
    /// Searches each component without following links or hydrating cloud
    /// placeholders. It checks existence only; it never lists cache contents.
    private static func existingRealDirectory(_ url: URL) -> Bool {
        guard let url = normalized(url) else { return false }
        var parent = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        for part in url.path.split(separator: "/") {
            let component = String(part)
            var before = stat()
            guard fstatat(parent, component, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_mode & S_IFMT == S_IFDIR, before.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
            let next = openat(parent, component, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            var opened = stat()
            guard fstat(next, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino, opened.st_mode & S_IFMT == S_IFDIR, opened.st_flags & UInt32(SF_DATALESS) == 0 else { close(next); return false }
            close(parent); parent = next
        }
        return true
    }
}
