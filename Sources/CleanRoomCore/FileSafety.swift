import Foundation
import Darwin

public enum FileSafety {
    public static func identity(_ url: URL) -> FileIdentity? {
        var s = stat()
        guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return FileIdentity(device: UInt64(s.st_dev), inode: UInt64(s.st_ino), size: Int64(s.st_size), modified: Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9)
    }
    public static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
    public static func isSymbolicLink(_ url: URL) -> Bool {
        var s = stat(); return lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFLNK
    }
    public static func isDataless(_ url: URL) -> Bool {
        var s = stat()
        return lstat(url.path, &s) == 0 && (s.st_flags & UInt32(SF_DATALESS)) != 0
    }
    public static func hasSymlinkComponent(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isSymbolicLink(current) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
    public static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let p = url.standardizedFileURL.path
        let h = home.standardizedFileURL.path
        let exact = ["/", "/Applications", "/Users", "/Volumes", "/Library", "/private", "/private/tmp", "/tmp", h, h + "/Library", h + "/Applications", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", h + "/Movies", h + "/Music", h + "/.Trash", h + "/Library/Caches", h + "/Library/Logs", h + "/Library/Application Support", h + "/Library/Preferences", h + "/Library/LaunchAgents"]
        let excluded = ["/System", "/bin", "/sbin", "/usr", "/Library/Apple", "/Library/LaunchDaemons", "/Library/LaunchAgents", h + "/Library/Keychains", h + "/Library/Containers", h + "/Library/Group Containers", h + "/.ssh", h + "/.gnupg", h + "/.Trash", h + "/Library/LaunchAgents"]
        return exact.contains(p) || excluded.contains { contains($0, p) }
    }
}
