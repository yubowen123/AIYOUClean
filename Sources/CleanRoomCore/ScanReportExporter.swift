import Foundation
import Darwin

public enum ScanReportExportError: LocalizedError {
    case invalidDestination(String)
    case destinationExists
    case busy(String)
    case filesystem(String, Int32)
    case incompleteStore
    public var errorDescription: String? {
        switch self {
        case .invalidDestination(let reason): return "导出路径无效：" + reason
        case .destinationExists: return "目标文件已存在。请选择一个新的文件名；不会覆盖已有文件。"
        case .busy(let name): return "另一项重操作正在运行：" + name
        case .filesystem(let operation, let code): return "导出报告无法" + operation + "（errno \(code)）。"
        case .incompleteStore: return "结果存储在导出期间发生变化；未发布不完整的导出文件。"
        }
    }
}

/// Writes self-contained ScanReport JSON, one item at a time. The destination
/// must not exist. Publication uses a same-directory atomic exclusive rename,
/// preventing a race from overwriting a file chosen by another writer.
public enum ScanReportExporter {
    public static func write(_ report: ScanReport, to destination: URL,
                             isCancelled: @Sendable () -> Bool = { false }) throws {
        guard let permit = WorkBudget.tryAcquire("导出全部扫描结果") else {
            throw ScanReportExportError.busy(WorkBudget.currentTaskName ?? "请稍后再试")
        }
        defer { permit.release() }
        if isCancelled() { throw CancellationError() }
        guard destination.isFileURL, destination.path.hasPrefix("/") else {
            throw ScanReportExportError.invalidDestination("需要本地绝对路径。")
        }
        let target = destination
        let parent = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !target.pathComponents.contains(".."), !target.pathComponents.contains(".") else {
            throw ScanReportExportError.invalidDestination("父目录包含符号链接或文件名无效。")
        }
        let directoryFD = try ScanOwnedLocation.openDirectory(parent)
        defer { Darwin.close(directoryFD) }
        var directoryIdentity = stat()
        guard fstat(directoryFD, &directoryIdentity) == 0 else { throw ScanReportExportError.filesystem("核对父目录", errno) }
        var existing = stat()
        if fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw ScanReportExportError.destinationExists }
        guard errno == ENOENT else { throw ScanReportExportError.filesystem("检查目标文件", errno) }
        let temporaryName = ".AIYOUClean-export-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScanReportExportError.filesystem("创建临时文件", errno) }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, temporaryName, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var metadata = report
        metadata.items = []
        metadata.resultStore = nil // Export is independent of an ephemeral DB.
        let store: ScanResultStore?
        let expectedCount: Int
        if let reference = report.resultStore {
            let source = try ScanResultStore(reference: reference, readOnly: true)
            let statistics = try source.statistics()
            metadata.totalItemCount = statistics.totalCount
            metadata.processableItemCount = statistics.processableCount
            metadata.allItemsBytes = statistics.totalBytes
            expectedCount = statistics.totalCount
            store = source
        } else {
            expectedCount = report.items.count
            metadata.totalItemCount = expectedCount
            metadata.processableItemCount = report.items.lazy.filter(\.canTrash).count
            metadata.allItemsBytes = report.items.reduce(Int64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.bytes)
                return overflow ? Int64.max : sum
            }
            store = nil
        }
        // Only the small metadata object is encoded as a whole. No full report
        // items array or complete exported file is materialized as Data.
        let metadataData = try encoder.encode(metadata)
        guard var object = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
            throw ScanReportExportError.invalidDestination("报告元数据无法编码。")
        }
        object.removeValue(forKey: "items")
        var opening = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard opening.last == 0x7D else { throw ScanReportExportError.incompleteStore }
        opening.removeLast()
        try handle.write(contentsOf: opening)
        try handle.write(contentsOf: Data((object.isEmpty ? "\"items\":[\n" : ",\"items\":[\n").utf8))
        var written = 0
        func append(_ item: ScanItem) throws {
            try autoreleasepool {
                if isCancelled() { throw CancellationError() }
                if written > 0 { try handle.write(contentsOf: Data(",\n".utf8)) }
                try handle.write(contentsOf: encoder.encode(item))
                written += 1
            }
        }
        if let store { try store.forEachItem { try append($0) } }
        else { for item in report.items { try append(item) } }
        guard written == expectedCount else { throw ScanReportExportError.incompleteStore }
        try handle.write(contentsOf: Data("\n]}\n".utf8))
        if isCancelled() { throw CancellationError() }
        guard fsync(fd) == 0 else { throw ScanReportExportError.filesystem("同步临时文件", errno) }
        let currentParentFD = try ScanOwnedLocation.openDirectory(parent)
        defer { Darwin.close(currentParentFD) }
        var currentParent = stat()
        guard fstat(currentParentFD, &currentParent) == 0,
              currentParent.st_dev == directoryIdentity.st_dev, currentParent.st_ino == directoryIdentity.st_ino else {
            throw ScanReportExportError.invalidDestination("父目录在导出期间发生变化。")
        }
        guard renameatx_np(directoryFD, temporaryName, directoryFD, name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ScanReportExportError.destinationExists }
            throw ScanReportExportError.filesystem("发布最终文件", code)
        }
        _ = fsync(directoryFD)
    }
}
