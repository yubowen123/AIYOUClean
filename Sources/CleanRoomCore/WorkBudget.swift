import Foundation
import Darwin

/// One disk-/memory-heavy operation at a time across all modules in this process.
public enum WorkBudget {
    private static let lock = NSLock()
    private static var owner: (UUID, String)?
    public static var currentTaskName: String? { lock.lock(); defer { lock.unlock() }; return owner?.1 }
    public static func tryAcquire(_ name: String) -> WorkPermit? {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return nil }
        let id = UUID(); owner = (id, name); return WorkPermit(id: id, name: name)
    }
    fileprivate static func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner?.0 == id { owner = nil }
    }
}
public final class WorkPermit: @unchecked Sendable {
    fileprivate let id: UUID
    public let name: String
    fileprivate init(id: UUID, name: String) { self.id = id; self.name = name }
    public func release() { WorkBudget.release(id) }
    deinit { release() }
}
public enum ProcessResources {
    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
