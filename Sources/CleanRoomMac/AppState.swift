import SwiftUI
import AppKit
import Combine
import CleanRoomCore

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// The scanner writes one replaceable slot; it never schedules work on MainActor.
private final class ScanProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (Int, String)?
    private var open = true
    func publish(_ count: Int, _ path: String) {
        lock.lock(); defer { lock.unlock() }
        if open { latest = (count, String(path.prefix(4096))) }
    }
    func take() -> (Int, String)? { lock.lock(); defer { lock.unlock() }; let value = latest; latest = nil; return value }
    func close() { lock.lock(); open = false; latest = nil; lock.unlock() }
}
private final class AppStateReference: @unchecked Sendable {
    @MainActor weak var value: AppState?
    @MainActor init(_ value: AppState) { self.value = value }
}

private struct ScanTrashResult: Sendable {
    let outcome: TrashOutcome
    let paths: [String]
    let statistics: ScanResultStatistics?
    let error: String?
}

enum Destination: Hashable {
    case dashboard, smartCare, scan(ScanKind), maintenance, history, about, malware, monitor, advancedCleanup, privacy, preferences
}

@MainActor
final class AppState: ObservableObject {
    @Published var destination: Destination? = .dashboard {
        didSet {
            guard oldValue != destination else { return }
            if case let .scan(kind) = destination, !ProductFeatures.allows(kind) { destination = .dashboard }
            clearSelection(); showTrashConfirmation = false; restoreCandidate = nil
            pageCancellation?.cancel(); pageTask?.cancel(); pageRequestID = UUID()
            pageTask = nil; pageCancellation = nil; pageLoading = false
            visibleItems = []; visibleIDs = []; query = ""
            if report != nil { requestPage(reset: true) }
        }
    }
    // One recent standard-scan report survives navigation. Feature controllers
    // own their own bounded pages and disk references in featureStates.
    @Published private(set) var latestReport: ScanReport?
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var selectedItems: [ScanItem] = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var roots: [URL] = []
    @Published private(set) var completeScan = true
    @Published var query = "" { didSet { if query != oldValue { requestPage(reset: true, debounce: true) } } }
    @Published var largestFirst = true { didSet { if largestFirst != oldValue { requestPage(reset: true) } } }
    @Published private(set) var visibleItems: [ScanItem] = []
    @Published private(set) var filteredCount = 0
    @Published private(set) var pageIndex = 0
    @Published private(set) var reportTotalBytes: Int64 = 0
    @Published private(set) var maximumItemBytes: Int64 = 0
    @Published private(set) var reportItemCount = 0
    @Published private(set) var processableItemCount = 0
    @Published private(set) var pageLoading = false
    @Published private(set) var pageError: String?
    @Published var busy = false
    @Published var busyTitle = ""
    @Published var progressCount = 0
    @Published var progressPath = ""
    @Published var snapshot = SystemInfo.snapshot()
    @Published private(set) var processResidentBytes = ProcessResources.residentBytes()
    @Published var history: [TrashRecord] = []
    @Published private(set) var historyPageIndex = 0
    @Published private(set) var historyHasOlder = false
    @Published private(set) var historyWarning: String?
    @Published var message: String?
    @Published var showTrashConfirmation = false
    @Published var restoreCandidate: TrashRecord?
    let pageSize = 200
    let taskCenter: DetectionTaskCenter
    let featureStates: FeatureStateRegistry
    private let trashManagerFactory: @Sendable () -> TrashManager
    private var taskCenterChanges: AnyCancellable?
    private var detectionID: UUID?
    private(set) var runningKind: ScanKind?
    var detectionUnavailable: Bool { busy || taskCenter.isBusy }
    var isCurrentScanRunning: Bool { isScanning && runningKind == kind }
    // Legacy/mock reports of at most one page can remain synchronous. Larger
    // legacy reports are migrated to the same disk store, never cut off.
    private var fallbackItems: [ScanItem] = []
    private var pendingProcessedPaths: [String] = []
    private let reportQueue = DispatchQueue(label: "local.aiyou.AIYOUClean.result-pages", qos: .userInitiated)
    private var reportGeneration = UUID()
    private var pageRequestID = UUID()
    private var pageCancellation: CancellationFlag?
    private var pageTask: Task<Void, Never>?
    private var legacyImportInProgress = false
    private var visibleIDs: Set<String> = []
    private var cancellation: CancellationFlag?
    private var mailbox: ScanProgressMailbox?
    private var scanID: UUID?
    private var progressPump: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var systemRefreshTask: Task<Void, Never>?
    private var presentationActive = true
    private var discardScanResult = false
    private var ignoreRuleChanges: AnyCancellable?

    init(taskCenter: DetectionTaskCenter? = nil, trashManagerFactory: (@Sendable () -> TrashManager)? = nil) {
        let center = taskCenter ?? .shared
        self.trashManagerFactory = trashManagerFactory ?? { TrashManager() }
        self.taskCenter = center; self.featureStates = FeatureStateRegistry(tasks: center)
        taskCenterChanges = center.$active.removeDuplicates {
            $0?.id == $1?.id && $0?.isCancelling == $1?.isCancelling
        }.sink { [weak self] _ in self?.objectWillChange.send() }
        reloadHistory()
        let receiver = AppStateReference(self)
        ignoreRuleChanges = NotificationCenter.default.publisher(for: IgnoreRuleStore.didChangeNotification).sink { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { receiver.value?.ignoreRulesDidChange() }
            } else {
                DispatchQueue.main.async { receiver.value?.ignoreRulesDidChange() }
            }
        }
    }
    private func ignoreRulesDidChange() {
        discardScanResult = true
        if isScanning { cancelScan() }
        invalidateReport(); showTrashConfirmation = false
        progressPath = "忽略清单已更新；请重新扫描。"
    }
    var kind: ScanKind? { if case let .scan(kind) = destination, ProductFeatures.allows(kind) { return kind }; return nil }
    var supportsStandardScan: Bool { kind != nil && kind != .spaceLens }
    var report: ScanReport? { latestReport?.kind == kind ? latestReport : nil }
    var isScanning: Bool { cancellation != nil }
    var pageCount: Int { max(1, (filteredCount + pageSize - 1) / pageSize) }
    var firstVisibleNumber: Int { filteredCount == 0 ? 0 : pageIndex * pageSize + 1 }
    var lastVisibleNumber: Int { min(filteredCount, (pageIndex + 1) * pageSize) }
    func memoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
    var batterySummary: String {
        let raw = snapshot.battery, lower = raw.lowercased()
        guard let range = raw.range(of: #"\b\d{1,3}%"#, options: .regularExpression) else { return raw.contains("AC Power") ? "交流电源" : "未读取到电池状态" }
        let status: String
        if lower.contains("discharging") { status = "电池供电" }
        else if lower.contains("charging") { status = "充电中" }
        else if lower.contains("charged") { status = "已充满" }
        else if raw.contains("AC Power") { status = "已接电源" }
        else { status = "电池供电" }
        return String(raw[range]) + " · " + status
    }
    func navigate(_ kind: ScanKind) { guard ProductFeatures.allows(kind) else { return }; destination = .scan(kind) }
    func resumePresentation() {
        presentationActive = true
        if report != nil { requestPage(reset: false) }
    }
    func suspendPresentation() {
        presentationActive = false
        clearSelection(); showTrashConfirmation = false; restoreCandidate = nil
        pageCancellation?.cancel(); pageTask?.cancel(); pageRequestID = UUID()
        pageTask = nil; pageCancellation = nil; pageLoading = false
    }
    private func invalidateReport() {
        let oldReference = latestReport?.resultStore
        reportGeneration = UUID(); pageRequestID = UUID()
        pageCancellation?.cancel(); pageCancellation = nil; pageTask?.cancel(); pageTask = nil
        latestReport = nil; fallbackItems = []; pendingProcessedPaths = []; visibleItems = []; visibleIDs = []
        filteredCount = 0; pageIndex = 0; maximumItemBytes = 0; reportTotalBytes = 0
        reportItemCount = 0; processableItemCount = 0; pageLoading = false; pageError = nil; legacyImportInProgress = false; clearSelection()
        if let oldReference { reportQueue.async { try? ScanResultStore.remove(oldReference) } }
    }
    private func acceptReport(_ value: ScanReport) {
        // A ScanReport's array is only a scanner preview. Never retain it along
        // with a second full UI copy or mistake its count for the store total.
        invalidateReport()
        var metadata = value; metadata.items = []
        latestReport = metadata
        reportItemCount = value.totalItemCount ?? value.items.count
        processableItemCount = value.processableItemCount ?? 0
        reportTotalBytes = value.allItemsBytes ?? 0
        if value.resultStore != nil { requestPage(reset: true); return }
        if value.items.count <= pageSize {
            fallbackItems = value.items; requestPage(reset: true); return
        }
        // Import old in-memory reports off MainActor. This path serves legacy
        // callers/mocks; normal scans already return a store reference.
        let generation = reportGeneration, receiver = AppStateReference(self), queue = reportQueue
        let token = CancellationFlag(); pageCancellation = token; pageLoading = true; legacyImportInProgress = true
        pageTask = Task {
            let outcome: Result<ScanResultReference, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    var partialReference: ScanResultReference?
                    do {
                        let reference = try autoreleasepool { () throws -> ScanResultReference in
                            let store = try ScanResultStore.createTemporary()
                            partialReference = store.reference
                            for item in value.items {
                                if token.isCancelled { throw CancellationError() }
                                try autoreleasepool { try store.append(item) }
                            }
                            try store.flush()
                            return store.reference
                        }
                        continuation.resume(returning: .success(reference))
                    } catch {
                        if let partialReference { try? ScanResultStore.remove(partialReference) }
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            guard let target = receiver.value, target.reportGeneration == generation, !token.isCancelled else {
                if case .success(let reference) = outcome { queue.async { try? ScanResultStore.remove(reference) } }
                return
            }
            target.pageTask = nil; target.pageCancellation = nil; target.legacyImportInProgress = false
            switch outcome {
            case .success(let reference):
                target.latestReport?.resultStore = reference
                target.requestPage(reset: true)
            case .failure(let error):
                target.pageLoading = false; target.pageError = "结果存储读取失败：" + error.localizedDescription
            }
        }
    }
    private func requestPage(reset: Bool, debounce: Bool = false) {
        if legacyImportInProgress { if reset { pageIndex = 0 }; clearSelection(); return }
        pageCancellation?.cancel(); pageTask?.cancel(); pageTask = nil
        pageRequestID = UUID(); clearSelection(); pageError = nil
        if reset { pageIndex = 0 }
        visibleItems = []; visibleIDs = []
        guard let report else { filteredCount = 0; pageLoading = false; return }
        guard let reference = report.resultStore else {
            // Bounded one-page fallback, preserving all entries of small mocks.
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var rows = fallbackItems.filter {
                needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle) || $0.category.localizedCaseInsensitiveContains(needle) || $0.detail.localizedCaseInsensitiveContains(needle)
            }
            rows.sort {
                if largestFirst && $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            filteredCount = rows.count; reportItemCount = fallbackItems.count
            processableItemCount = fallbackItems.filter(\.canTrash).count
            reportTotalBytes = fallbackItems.reduce(0) { $0 + $1.bytes }
            maximumItemBytes = fallbackItems.map(\.bytes).max() ?? 0
            visibleItems = rows; visibleIDs = Set(rows.map(\.id)); pageLoading = false
            return
        }
        let requestID = pageRequestID, generation = reportGeneration
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines), bySize = largestFirst
        let offset = pageIndex * pageSize, limit = pageSize, token = CancellationFlag()
        let receiver = AppStateReference(self), queue = reportQueue
        let processedPaths = pendingProcessedPaths
        pageCancellation = token; pageLoading = true
        pageTask = Task {
            if debounce {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
            guard !token.isCancelled, !Task.isCancelled else { return }
            let outcome: Result<ScanResultPage, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    do {
                        if token.isCancelled { throw CancellationError() }
                        if !processedPaths.isEmpty {
                            _ = try ScanResultStore(reference: reference, readOnly: false).removeProcessedPaths(processedPaths)
                        }
                        let store = try ScanResultStore(reference: reference, readOnly: true)
                        let page = try store.page(offset: offset, limit: limit, query: needle, largestFirst: bySize, isCancelled: { token.isCancelled })
                        continuation.resume(returning: .success(page))
                    } catch { continuation.resume(returning: .failure(error)) }
                }
            }
            guard let target = receiver.value, target.pageRequestID == requestID, target.reportGeneration == generation, !token.isCancelled else { return }
            target.pageTask = nil; target.pageCancellation = nil; target.pageLoading = false
            switch outcome {
            case .success(let page):
                target.pendingProcessedPaths = []
                target.latestReport?.totalItemCount = page.statistics.totalCount
                target.latestReport?.processableItemCount = page.statistics.processableCount
                target.latestReport?.allItemsBytes = page.statistics.totalBytes
                let last = max(0, (page.filteredCount - 1) / target.pageSize)
                if target.pageIndex > last {
                    target.pageIndex = last; target.requestPage(reset: false); return
                }
                target.visibleItems = page.items; target.visibleIDs = Set(page.items.map(\.id))
                target.filteredCount = page.filteredCount
                target.reportItemCount = page.statistics.totalCount
                target.processableItemCount = page.statistics.processableCount
                target.reportTotalBytes = page.statistics.totalBytes
                target.maximumItemBytes = page.statistics.maximumBytes
            case .failure(let error):
                target.pageError = "结果分页读取失败：" + error.localizedDescription
            }
        }
    }
    func previousPage() { guard !busy, !pageLoading, pageIndex > 0 else { return }; pageIndex -= 1; requestPage(reset: false) }
    func nextPage() { guard !busy, !pageLoading, pageIndex + 1 < pageCount else { return }; pageIndex += 1; requestPage(reset: false) }
    func refreshSystem() {
        guard systemRefreshTask == nil else { return }
        let receiver = AppStateReference(self)
        systemRefreshTask = Task {
            let value = await Task.detached(priority: .utility) { (SystemInfo.snapshot(), ProcessResources.residentBytes()) }.value
            guard let target = receiver.value else { return }
            target.snapshot = value.0; target.processResidentBytes = value.1; target.systemRefreshTask = nil
        }
    }
    func chooseRoots() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "选择本次扫描范围。取消不会改变当前范围。"; panel.prompt = "使用这些文件夹"
        if panel.runModal() == .OK { setRoots(panel.urls) }
    }
    func resetRoots() { setRoots([]) }
    private func setRoots(_ value: [URL]) { guard !busy else { return }; roots = value; invalidateReport(); query = "" }
    func setCompleteScan(_ value: Bool) {
        guard !busy, completeScan != value else { return }
        completeScan = value
        invalidateReport(); showTrashConfirmation = false
    }
    func scan() {
        guard let kind, !busy, presentationActive, supportsStandardScan, ProductFeatures.allows(kind) else { return }
        guard let job = taskCenter.begin("扫描" + kind.title, destination: .scan(kind), cancel: { [weak self] in self?.cancelScan() }) else {
            message = "已有任务正在运行：" + (taskCenter.active?.title ?? "请稍后再试")
            return
        }
        detectionID = job; runningKind = kind
        discardScanResult = false
        invalidateReport(); progressCount = 0; progressPath = "正在准备扫描…"
        busyTitle = "扫描\(kind.title)"; busy = true
        // Interactive scans always continue to completion. The compatibility
        // completeScan property no longer enables a stopping quick-mode path.
        let options = ScanOptions(roots: kind == .protection ? [] : roots, maxFiles: Int.max,
                                  maxSeconds: .infinity, maxResults: pageSize,
                                  memoryBudgetBytes: 512 * 1024 * 1024, scanToCompletion: true)
        let token = CancellationFlag(), slot = ScanProgressMailbox(), requestID = UUID(), receiver = AppStateReference(self)
        let queue = reportQueue
        cancellation = token; mailbox = slot; scanID = requestID
        progressPump = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard !Task.isCancelled, let target = receiver.value, target.scanID == requestID, !token.isCancelled else { return }
                if let value = slot.take() {
                    target.progressCount = value.0; target.progressPath = value.1
                    target.taskCenter.update(job, count: value.0, path: value.1)
                }
            }
        }
        let center = taskCenter
        activeTask = Task {
            defer { center.finish(job) }
            let result = await Task.detached(priority: .userInitiated) {
                CleanRoomCore.Scanner().scan(kind, options: options, progress: { count, path in slot.publish(count, path) }, isCancelled: { token.isCancelled })
            }.value
            slot.close()
            guard let target = receiver.value, target.scanID == requestID else {
                if let reference = result.resultStore { queue.async { try? ScanResultStore.remove(reference) } }
                return
            }
            target.progressPump?.cancel(); target.progressPump = nil
            target.busy = false; target.cancellation = nil; target.mailbox = nil; target.scanID = nil
            target.activeTask = nil; target.detectionID = nil; target.runningKind = nil
            let discard = target.discardScanResult; target.discardScanResult = false
            guard !discard else {
                if let reference = result.resultStore { queue.async { try? ScanResultStore.remove(reference) } }
                return
            }
            target.progressCount = result.visitedFiles
            center.update(job, count: result.visitedFiles, path: token.isCancelled ? "检测已取消，结果仅含已检查部分" : "检测已结束")
            target.acceptReport(result)
            if token.isCancelled { target.message = "扫描已取消。仅显示已扫描的部分，结果不完整。" }
        }
    }
    func cancelScan() {
        guard isScanning else { return }
        if let detectionID { taskCenter.markCancelling(detectionID) }
        cancellation?.cancel(); mailbox?.close(); progressPump?.cancel(); progressPump = nil
        progressPath = "正在取消；等待当前文件操作结束…"
    }
    func toggle(_ item: ScanItem) {
        guard item.canTrash, !busy, pendingProcessedPaths.isEmpty, visibleIDs.contains(item.id) else { return }
        if selected.contains(item.id) { selected.remove(item.id); selectedItems.removeAll { $0.id == item.id }; selectedBytes -= item.bytes }
        else { selected.insert(item.id); selectedItems.append(item); selectedBytes += item.bytes }
    }
    func clearSelection() { selected = []; selectedItems = []; selectedBytes = 0 }
    func trashSelected() {
        guard !busy, pendingProcessedPaths.isEmpty, let actionKind = kind, !selectedItems.isEmpty else { return }
        let items = selectedItems
        guard let job = taskCenter.begin("移到废纸篓", destination: .scan(actionKind), cancel: nil) else { message = "已有任务正在运行，请等待其结束。"; return }
        let center = taskCenter
        let factory = trashManagerFactory, reference = latestReport?.resultStore, generation = reportGeneration
        let queue = reportQueue
        pageCancellation?.cancel(); pageTask?.cancel(); pageRequestID = UUID()
        pageTask = nil; pageCancellation = nil; pageLoading = false
        busy = true; busyTitle = "移到废纸篓"; showTrashConfirmation = false
        activeTask = Task { [weak self] in
            defer { center.finish(job) }
            let result = await Task.detached(priority: .userInitiated) {
                Self.processTrash(items, factory: factory, reference: reference, queue: queue)
            }.value
            self?.completeTrash(result, kind: actionKind, reference: reference, generation: generation)
        }
    }
    private nonisolated static func processTrash(_ items: [ScanItem], factory: @Sendable () -> TrashManager,
                                                 reference: ScanResultReference?, queue: DispatchQueue) -> ScanTrashResult {
        let outcome = factory().trash(items)
        let paths = outcome.records.map { record in
            items.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path.utf8.elementsEqual(record.originalPath.utf8) }?.path ?? record.originalPath
        }
        guard !paths.isEmpty, let reference else { return .init(outcome: outcome, paths: paths, statistics: nil, error: nil) }
        do {
            let statistics = try queue.sync {
                try ScanResultStore(reference: reference, readOnly: false).removeProcessedPaths(paths)
            }
            return .init(outcome: outcome, paths: paths, statistics: statistics, error: nil)
        } catch {
            return .init(outcome: outcome, paths: paths, statistics: nil, error: "文件已处理，但结果列表更新失败：" + error.localizedDescription)
        }
    }
    private func completeTrash(_ result: ScanTrashResult, kind actionKind: ScanKind, reference: ScanResultReference?, generation: UUID) {
        let outcome = result.outcome, paths = result.paths
        clearSelection(); busy = false; activeTask = nil; reloadHistory(); refreshSystem()
        if reportGeneration == generation, latestReport?.kind == actionKind {
            if let statistics = result.statistics {
                latestReport?.totalItemCount = statistics.totalCount
                latestReport?.processableItemCount = statistics.processableCount
                latestReport?.allItemsBytes = statistics.totalBytes
                reportItemCount = statistics.totalCount; processableItemCount = statistics.processableCount
                reportTotalBytes = statistics.totalBytes; maximumItemBytes = statistics.maximumBytes
            } else if reference == nil && !paths.isEmpty {
                fallbackItems.removeAll { item in paths.contains { FileSafety.contains($0, item.path) } }
                reportItemCount = fallbackItems.count; processableItemCount = fallbackItems.filter(\.canTrash).count
                reportTotalBytes = fallbackItems.reduce(0) { $0 + $1.bytes }; maximumItemBytes = fallbackItems.map(\.bytes).max() ?? 0
                latestReport?.totalItemCount = reportItemCount
                latestReport?.processableItemCount = processableItemCount
                latestReport?.allItemsBytes = reportTotalBytes
            }
            if let error = result.error { pendingProcessedPaths = paths; pageError = error }
            else if presentationActive, report != nil { requestPage(reset: false) }
        }
        var lines = ["\(actionKind.title)：已移到废纸篓 \(outcome.records.count) 项。"]
        lines.append(result.error ?? "剩余检查结果已保留，可继续选择处理。")
        if !outcome.errors.isEmpty { lines.append("未处理项目：\n" + outcome.errors.joined(separator: "\n")) }
        if let historyWarning { lines.append(historyWarning) }
        message = lines.joined(separator: "\n")
    }
    func reloadHistory() {
        let manager = trashManagerFactory()
        let rows = manager.records(limit: 201)
        history = Array(rows.prefix(200)); historyHasOlder = rows.count > 200; historyPageIndex = 0
        historyWarning = manager.historyWarning
        if let warning = manager.historyWarning { message = warning }
    }
    func olderHistory() {
        guard !busy, historyHasOlder, let last = history.last else { return }
        let manager = trashManagerFactory(), rows = manager.records(limit: 201, before: TrashHistoryCursor(last))
        historyWarning = manager.historyWarning
        guard manager.historyWarning == nil else { return }
        if rows.isEmpty { historyHasOlder = false; return }
        history = Array(rows.prefix(200)); historyHasOlder = rows.count > 200; historyPageIndex += 1
    }
    func newerHistory() {
        guard !busy, historyPageIndex > 0, let first = history.first else { return }
        let manager = trashManagerFactory(), rows = manager.records(limit: 200, after: TrashHistoryCursor(first))
        historyWarning = manager.historyWarning
        guard manager.historyWarning == nil else { return }
        if rows.isEmpty { reloadHistory(); return }
        history = rows; historyHasOlder = true; historyPageIndex -= 1
    }
    func restore(_ record: TrashRecord) {
        guard !busy else { return }
        guard let job = taskCenter.begin("恢复文件", destination: .history, cancel: nil) else { message = "已有任务正在运行，请等待其结束。"; return }
        let center = taskCenter
        let factory = trashManagerFactory
        restoreCandidate = nil; busy = true; busyTitle = "恢复文件"
        activeTask = Task { [weak self] in
            defer { center.finish(job) }
            let error: String? = await Task.detached(priority: .userInitiated) {
                do { try factory().restore(record); return nil } catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            busy = false; activeTask = nil; reloadHistory(); refreshSystem()
            if error == nil { invalidateReport() }
            if presentationActive { message = (error.map { "恢复失败：\($0)" } ?? "已恢复：\(record.originalPath)") + (historyWarning.map { "\n\n" + $0 } ?? "") }
        }
    }
    func reveal(_ path: String) {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { message = "这个项目没有可定位的本地文件。"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
    func exportReport() {
        guard !detectionUnavailable, !pageLoading, var report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AIYOUClean-\(report.kind.rawValue).json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if report.resultStore == nil { report.items = fallbackItems }
        guard let job = taskCenter.begin("导出全部扫描结果", destination: .scan(report.kind), cancel: nil) else { message = "已有任务正在运行，请等待其结束。"; return }
        let center = taskCenter
        let value = report, receiver = AppStateReference(self), queue = reportQueue
        busy = true; busyTitle = "导出全部扫描结果"
        activeTask = Task {
            defer { center.finish(job) }
            let error: String? = await withCheckedContinuation { continuation in
                queue.async {
                    do { try ScanReportExporter.write(value, to: url); continuation.resume(returning: nil) }
                    catch { continuation.resume(returning: error.localizedDescription) }
                }
            }
            guard let target = receiver.value else { return }
            target.busy = false; target.activeTask = nil
            if target.presentationActive { target.message = error.map { "导出失败：" + $0 } ?? "已导出全部扫描结果：\(url.path)" }
        }
    }
}
