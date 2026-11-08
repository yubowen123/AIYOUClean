import Foundation

public struct TrashInspectionPage: Sendable {
    public let items: [TrashInspectionItem]
    public let filteredCount: Int
    public let statistics: ScanResultStatistics
}

/// The generic store owns the SQLite session and its deletion rules. Each
/// bounded row preserves the complete inspection receipt in its JSON detail.
public final class TrashInspectionStore: @unchecked Sendable {
    private let store: ScanResultStore
    private static let category = "AIYOUClean.TrashInspection.v1"
    public var reference: ScanResultReference { store.reference }
    private init(store: ScanResultStore) { self.store = store }
    static func createTemporary() throws -> TrashInspectionStore {
        try TrashInspectionStore(store: ScanResultStore.createTemporary())
    }
    public convenience init(reference: ScanResultReference, readOnly: Bool = true) throws {
        try self.init(store: ScanResultStore(reference: reference, readOnly: readOnly))
    }
    func append(_ item: TrashInspectionItem) throws {
        let detail = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        try store.append(ScanItem(path: item.path, category: Self.category, bytes: item.bytes, detail: detail,
                                  canTrash: item.canPermanentlyDelete, identity: item.identity, scopeRoot: item.trashRoot))
    }
    func flush() throws { try store.flush() }
    public func statistics() throws -> ScanResultStatistics { try store.statistics() }
    public func removeProcessedPaths(_ paths: [String]) throws -> ScanResultStatistics {
        try store.removeProcessedPaths(paths)
    }
    private func decode(_ row: ScanItem) throws -> TrashInspectionItem {
        guard row.category == Self.category else { throw ExtendedCleanupError.rejected("不是废纸篓清点结果。") }
        let item = try JSONDecoder().decode(TrashInspectionItem.self, from: Data(row.detail.utf8))
        guard item.path == row.path, item.trashRoot == row.scopeRoot, item.identity == row.identity,
              item.bytes == row.bytes, item.canPermanentlyDelete == row.canTrash else {
            throw ExtendedCleanupError.rejected("废纸篓清点收据与项目元数据不一致。")
        }
        return item
    }
    public func page(offset: Int = 0, limit: Int = 200, isCancelled: () -> Bool = { false }) throws -> TrashInspectionPage {
        let page = try store.page(offset: offset, limit: limit, largestFirst: false, isCancelled: isCancelled)
        return try .init(items: page.items.map { try decode($0) }, filteredCount: page.filteredCount, statistics: page.statistics)
    }
    public func forEachItem(_ body: (TrashInspectionItem) throws -> Void) throws {
        try store.forEachItem { try body(decode($0)) }
    }
    public static func remove(_ reference: ScanResultReference) throws { try ScanResultStore.remove(reference) }
}
