import Foundation
import Darwin

public enum IgnoreRuleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// Absolute, normalized path rules. A rule excludes the path and its descendants.
/// No glob, shell expansion, URL scheme or symlink resolution is performed.
public struct IgnoreRuleStore: Sendable {
    public static let didChangeNotification = Notification.Name("AIYOUClean.IgnoreRulesDidChange")
    public let home: URL
    public var fileURL: URL { home.appendingPathComponent("Library/Application Support/AIYOUClean/ignore-rules.json") }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.standardizedFileURL }
    public static func normalize(_ paths: [String]) throws -> [String] {
        guard paths.count <= 500 else { throw IgnoreRuleError.invalid("忽略清单最多500项。") }
        var normalized: [String] = [], seen = Set<String>()
        for path in paths {
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw IgnoreRuleError.invalid("忽略项必须是有效绝对路径，不能包含控制字符、相对路径或超过4096字节。") }
            let clean = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(clean).inserted { normalized.append(clean) }
        }
        return normalized.sorted()
    }
    public static func isExcluded(_ path: String, by rules: [String]) -> Bool {
        guard !rules.isEmpty, path.hasPrefix("/") else { return false }
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        return rules.contains { FileSafety.contains($0, clean) }
    }
    public func load() throws -> [String] {
        guard !FileSafety.hasSymlinkComponent(fileURL) else { throw IgnoreRuleError.invalid("忽略清单存储路径包含符号链接，已停止读取。") }
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            if errno == ENOENT { return [] }
            throw IgnoreRuleError.invalid("无法读取忽略清单属性（errno \(errno)）。")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_size <= 256_000, metadata.st_mode & 0o077 == 0 else { throw IgnoreRuleError.invalid("忽略清单必须是当前用户拥有、权限0600且不超过256KB的普通文件。") }
        let fd = try MalwareFiles.openRegular(fileURL); defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 256_001) ?? Data()
        guard data.count <= 256_000, FileSafety.identity(fileURL) == MalwareFiles.identity(metadata) else { throw IgnoreRuleError.invalid("忽略清单过大或读取期间发生变化。") }
        do { return try Self.normalize(JSONDecoder().decode([String].self, from: data)) }
        catch { throw IgnoreRuleError.invalid("忽略清单损坏或含无效路径，未继续扫描：\(error.localizedDescription)") }
    }
    public func save(_ paths: [String]) throws {
        let paths = try Self.normalize(paths), data = try JSONEncoder().encode(paths)
        guard data.count <= 256_000 else { throw IgnoreRuleError.invalid("忽略清单编码后超过256KB。") }
        let directory = fileURL.deletingLastPathComponent()
        guard !FileSafety.hasSymlinkComponent(fileURL) else { throw IgnoreRuleError.invalid("忽略清单存储路径包含符号链接，未写入。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try MalwareFiles.openDirectory(directory); defer { close(parent) }
        var parentMetadata = stat(); guard fstat(parent, &parentMetadata) == 0, parentMetadata.st_uid == getuid() else { throw IgnoreRuleError.invalid("忽略清单目录不属于当前用户。") }
        let temporaryName = ".ignore-rules-" + UUID().uuidString
        let fd = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IgnoreRuleError.invalid("无法创建忽略清单临时文件。") }
        defer { close(fd); _ = unlinkat(parent, temporaryName, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw IgnoreRuleError.invalid("忽略清单写入失败。") }; offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, let actualParent = FileSafety.identity(directory), actualParent.device == UInt64(parentMetadata.st_dev), actualParent.inode == UInt64(parentMetadata.st_ino), !FileSafety.isSymbolicLink(fileURL), renameat(parent, temporaryName, parent, fileURL.lastPathComponent) == 0 else { throw IgnoreRuleError.invalid("忽略清单原子保存失败或存储路径已变化。") }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: home.path)
    }
}
