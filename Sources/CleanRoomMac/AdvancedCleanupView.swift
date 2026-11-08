import SwiftUI
import AppKit
import Combine
import CleanRoomCore

private let advancedAccent = Color(red: 0.61, green: 0.49, blue: 1)
private let advancedSecondary = Color(red: 0.65, green: 0.68, blue: 0.78)
private enum AdvancedTab: String, CaseIterable, Identifiable { case candidates = "高级清理", trash = "废纸篓", versions = "文档历史"; var id: String { rawValue } }
private final class AdvancedProgressMailbox: @unchecked Sendable {
    private let lock = NSLock(); private var latest: (Int, String) = (0, "")
    private var closed = false
    func publish(_ count: Int, _ path: String) { lock.lock(); if !closed { latest = (count, String(path.prefix(2048))) }; lock.unlock() }
    func snapshot() -> (Int, String) { lock.lock(); defer { lock.unlock() }; return latest }
    func close() { lock.lock(); closed = true; latest = (0, ""); lock.unlock() }
}
private enum AdvancedPageResult: Sendable { case candidates(ScanResultPage), trash(TrashInspectionPage) }
private struct AdvancedProcessedResult: Sendable {
    let paths: [String]
    let errors: [String]
    let cancelled: Bool
    let reference: ScanResultReference?
    let statistics: ScanResultStatistics?
    let indexError: String?
    init(paths: [String], errors: [String] = [], cancelled: Bool = false, reference: ScanResultReference? = nil,
         statistics: ScanResultStatistics? = nil, indexError: String? = nil) {
        self.paths = paths; self.errors = errors; self.cancelled = cancelled; self.reference = reference
        self.statistics = statistics; self.indexError = indexError
    }
}
private enum AdvancedResult: Sendable {
    case cleanup(ExtendedCleanupReport), trash(TrashInspectionReport), deleted(AdvancedProcessedResult)
    case moved(AdvancedProcessedResult)
    case versions([DocumentHistoryVersion], [DocumentVersionArchiveRecord])
    case versionAction([DocumentHistoryVersion], [DocumentVersionArchiveRecord], String)
    case failure(String)
}
private struct AdvancedConfirmation: Identifiable, Sendable {
    enum Action: Sendable { case trash([ScanItem]), permanent([TrashInspectionItem]), archive(DocumentHistoryVersion), restore(DocumentVersionArchiveRecord) }
    let id = UUID(); let action: Action
}
private final class AdvancedPanelReference: @unchecked Sendable {
    @MainActor weak var value: AdvancedCleanupState?
    @MainActor init(_ value: AdvancedCleanupState) { self.value = value }
}
@MainActor
private final class AdvancedCleanupState: ObservableObject {
    let taskCenter: DetectionTaskCenter
    @Published var tab: AdvancedTab = .candidates
    @Published var category: ExtendedCleanupCategory = .developerCaches
    @Published private(set) var report: ExtendedCleanupReport?
    @Published private(set) var trashReport: TrashInspectionReport?
    @Published private(set) var versions: [DocumentHistoryVersion] = []
    @Published private(set) var archives: [DocumentVersionArchiveRecord] = []
    @Published private(set) var document: URL?
    @Published private(set) var busyTitle: String?
    @Published private(set) var progressCount = 0
    @Published private(set) var progressPath = ""
    @Published private(set) var errors: [String] = []
    @Published private(set) var movedPaths: Set<String> = []
    @Published var selected: Set<String> = []
    @Published var page = 0
    @Published var confirmation: AdvancedConfirmation?
    @Published var permanentPhrase = ""
    @Published var message: String?
    @Published private(set) var pageLoading = false
    @Published private(set) var pageError: String?
    @Published private(set) var candidatePage: [ScanItem] = []
    @Published private(set) var trashPage: [TrashInspectionItem] = []
    @Published private(set) var candidateIndexError: String?
    @Published private(set) var trashIndexError: String?
    private let resultQueue = DispatchQueue(label: "local.aiyou.AIYOUClean.advanced-pages", qos: .utility)
    private var pageID = UUID()
    private var pageToken: MalwareCancellation?
    private var pageTask: Task<Void, Never>?
    private var activeMailbox: AdvancedProgressMailbox?
    private var fallbackCandidates: [ScanItem] = []
    private var fallbackTrash: [TrashInspectionItem] = []
    private var token: MalwareCancellation?
    private var operation: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var operationID: UUID?
    private var operationTab: AdvancedTab?
    private var presentationActive = true
    private var discardOperationResult = false
    private var ignoreObserver: AnyCancellable?
    private let trashManagerFactory: @Sendable () -> TrashManager
    private let trashInspectorFactory: @Sendable () -> TrashInspector
    init(taskCenter: DetectionTaskCenter? = nil,
         trashManagerFactory: (@Sendable () -> TrashManager)? = nil,
         trashInspectorFactory: (@Sendable () -> TrashInspector)? = nil) {
        self.taskCenter = taskCenter ?? .shared
        self.trashManagerFactory = trashManagerFactory ?? { TrashManager() }
        self.trashInspectorFactory = trashInspectorFactory ?? { TrashInspector() }
        let receiver = AdvancedPanelReference(self)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        ignoreObserver = NotificationCenter.default.publisher(for: IgnoreRuleStore.didChangeNotification).receive(on: RunLoop.main).sink { note in
            guard note.object as? String == homePath else { return }
            MainActor.assumeIsolated { receiver.value?.ignoreRulesChanged() }
        }
    }
    var busy: Bool { busyTitle != nil }
    var processingIndexError: String? { tab == .candidates ? candidateIndexError : tab == .trash ? trashIndexError : nil }
    var pageCount: Int {
        let count: Int
        switch tab { case .candidates: count = report?.totalCount ?? 0; case .trash: count = trashReport?.totalCount ?? 0; case .versions: count = versions.count + archives.count }
        return max(1, (count + 199) / 200)
    }
    private func clearReports() {
        let references = [report?.resultStore, trashReport?.resultStore].compactMap { $0 }
        pageToken?.cancel(); pageToken = nil; pageTask?.cancel(); pageTask = nil; pageID = UUID()
        report = nil; trashReport = nil; candidatePage = []; trashPage = []; fallbackCandidates = []; fallbackTrash = []
        selected = []; page = 0; pageLoading = false; pageError = nil; confirmation = nil; movedPaths = []
        candidateIndexError = nil; trashIndexError = nil
        for reference in references { resultQueue.async { try? ScanResultStore.remove(reference) } }
    }
    private func invalidateCandidates() {
        let reference = report?.resultStore
        report = nil; fallbackCandidates = []; candidatePage = []; candidateIndexError = nil; movedPaths = []
        if tab == .candidates {
            pageToken?.cancel(); pageTask?.cancel(); pageID = UUID(); pageLoading = false
            selected = []; confirmation = nil; permanentPhrase = ""; page = 0
        }
        if let reference { resultQueue.async { try? ScanResultStore.remove(reference) } }
    }
    private func invalidateTrash() {
        let reference = trashReport?.resultStore
        trashReport = nil; fallbackTrash = []; trashPage = []; trashIndexError = nil
        if tab == .trash {
            pageToken?.cancel(); pageTask?.cancel(); pageID = UUID(); pageLoading = false
            selected = []; confirmation = nil; permanentPhrase = ""; page = 0
        }
        if let reference { resultQueue.async { try? ScanResultStore.remove(reference) } }
    }
    func switchContent() {
        guard !busy else { return }
        selected = []; confirmation = nil; permanentPhrase = ""; page = min(page, pageCount - 1); loadPage()
    }
    func switchCategory() { guard !busy else { return }; invalidateCandidates() }
    func previousPage() { guard !busy, !pageLoading, page > 0 else { return }; page -= 1; selected = []; loadPage() }
    func nextPage() { guard !busy, !pageLoading, page + 1 < pageCount else { return }; page += 1; selected = []; loadPage() }
    private func loadPage() {
        pageToken?.cancel(); pageTask?.cancel(); pageID = UUID(); selected = []; pageError = nil; confirmation = nil; permanentPhrase = ""
        guard presentationActive else { candidatePage = []; trashPage = []; pageLoading = false; return }
        guard tab != .versions else { pageLoading = false; return }
        let reference = tab == .candidates ? report?.resultStore : trashReport?.resultStore
        guard let reference else { candidatePage = fallbackCandidates; trashPage = fallbackTrash; pageLoading = false; return }
        candidatePage = []; trashPage = []; pageLoading = true
        let id = pageID, offset = page * 200, pageTab = tab, cancellation = MalwareCancellation()
        let receiver = AdvancedPanelReference(self), queue = resultQueue
        pageToken = cancellation
        pageTask = Task {
            let outcome: Result<AdvancedPageResult, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        if pageTab == .candidates {
                            let value = try ScanResultStore(reference: reference).page(offset: offset, largestFirst: false, isCancelled: { cancellation.isCancelled })
                            continuation.resume(returning: .success(.candidates(value)))
                        } else {
                            let value = try TrashInspectionStore(reference: reference).page(offset: offset, isCancelled: { cancellation.isCancelled })
                            continuation.resume(returning: .success(.trash(value)))
                        }
                    } catch { continuation.resume(returning: .failure(error)) }
                }
            }
            guard let target = receiver.value, target.presentationActive, target.pageID == id, !cancellation.isCancelled else { return }
            target.pageLoading = false; target.pageTask = nil; target.pageToken = nil
            switch outcome {
            case .success(.candidates(let page)):
                target.candidatePage = page.items
                target.report?.totalCount = page.statistics.totalCount; target.report?.totalBytes = page.statistics.totalBytes; target.report?.processableCount = page.statistics.processableCount
            case .success(.trash(let page)):
                target.trashPage = page.items
                target.trashReport?.totalCount = page.statistics.totalCount; target.trashReport?.totalBytes = page.statistics.totalBytes; target.trashReport?.processableCount = page.statistics.processableCount
            case .failure(let error): target.pageError = "分页结果读取失败：" + error.localizedDescription
            }
        }
    }
    func scan() {
        guard !busy else { return }
        if tab == .versions { loadVersions(); return }
        let tab = tab, category = category
        let inspectorFactory = trashInspectorFactory
        start(tab == .trash ? "清点废纸篓" : "扫描高级清理候选", clearResults: true) { token, mailbox in
            if tab == .trash { return .trash(inspectorFactory().scan(cancellation: token, progress: { mailbox.publish($0, $1) })) }
            return .cleanup(ExtendedCleanupScanner().scan(category, cancellation: token, progress: { mailbox.publish($0, $1) }))
        }
    }
    func chooseDocument() {
        guard !busy, !pageLoading else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "选择一个本地文档，只处理其系统历史版本；不会扫描其他文档。"
        if panel.runModal() == .OK, let url = panel.url {
            guard !taskCenter.isBusy else { message = "另一项检测或处理仍在运行；文档选择未变更。"; return }
            document = url; versions = []; page = 0; loadVersions()
        }
    }
    func loadVersions() {
        guard let document else { return }
        start("读取文档历史") { token, _ in
            guard !token.isCancelled else { return .failure("已取消读取文档历史。") }
            do { let archive = DocumentVersionArchive(); return .versions(try archive.list(document: document), try archive.records()) }
            catch { return .failure(error.localizedDescription) }
        }
    }
    func requestProcessing() {
        guard !busy, !pageLoading else { return }
        guard processingIndexError == nil else { message = processingIndexError; return }
        permanentPhrase = ""
        switch tab {
        case .candidates:
            let items = candidatePage.filter { selected.contains($0.path) && $0.canTrash && !movedPaths.contains($0.path) }
            if !items.isEmpty { confirmation = AdvancedConfirmation(action: .trash(items)) }
        case .trash:
            let items = trashPage.filter { selected.contains($0.path) && $0.canPermanentlyDelete }
            if !items.isEmpty { confirmation = AdvancedConfirmation(action: .permanent(items)) }
        case .versions: break
        }
    }
    func requestArchive(_ version: DocumentHistoryVersion) { guard !busy else { return }; confirmation = AdvancedConfirmation(action: .archive(version)) }
    func requestRestore(_ record: DocumentVersionArchiveRecord) { guard !busy else { return }; confirmation = AdvancedConfirmation(action: .restore(record)) }
    func perform(_ pending: AdvancedConfirmation) {
        guard !busy else { return }
        switch pending.action {
        case .trash where candidateIndexError != nil: message = candidateIndexError; return
        case .permanent where trashIndexError != nil: message = trashIndexError; return
        default: break
        }
        if case .permanent = pending.action, permanentPhrase != "永久删除" { message = "请输入“永久删除”确认不可恢复操作。"; return }
        let candidateReference = report?.resultStore, trashReference = trashReport?.resultStore
        let makeManager = trashManagerFactory, makeInspector = trashInspectorFactory, queue = resultQueue
        start("处理明确确认的项目") { token, mailbox in
            switch pending.action {
            case .trash(let items):
                let manager = makeManager(); var paths: [String] = [], errors: [String] = []
                let result = manager.trash(items, isCancelled: { token.isCancelled })
                paths = result.records.map(\.originalPath); errors = Array(result.errors.prefix(100))
                mailbox.publish(paths.count, "移入废纸篓")
                return .moved(Self.pruneProcessed(paths, errors: errors, cancelled: token.isCancelled,
                                                  reference: candidateReference, permanent: false, queue: queue))
            case .permanent(let items):
                let result = makeInspector().permanentlyDelete(items, confirmed: true, confirmationPaths: items.map(\.path), cancellation: token)
                mailbox.publish(result.deletedPaths.count, "永久删除已回读确认的项目")
                return .deleted(Self.pruneProcessed(result.deletedPaths, errors: result.errors, cancelled: result.cancelled,
                                                    reference: trashReference, permanent: true, queue: queue))
            case .archive(let version):
                do {
                    let archive = DocumentVersionArchive(); _ = try archive.archiveAndRemove(version, confirmed: true, cancellation: token)
                    return .versionAction(try archive.list(document: URL(fileURLWithPath: version.documentPath)), try archive.records(), "历史内容已备份并移出系统版本库；当前文档未替换。")
                } catch { return .failure(error.localizedDescription) }
            case .restore(let record):
                do {
                    let archive = DocumentVersionArchive(); try archive.restoreAsVersion(record, confirmed: true, cancellation: token)
                    return .versionAction(try archive.list(document: URL(fileURLWithPath: record.documentPath)), try archive.records(), "归档已添加为一个历史版本，当前文档内容未替换。")
                } catch { return .failure(error.localizedDescription) }
            }
        }
    }
    nonisolated private static func pruneProcessed(_ paths: [String], errors: [String], cancelled: Bool,
                                                    reference: ScanResultReference?, permanent: Bool,
                                                    queue: DispatchQueue) -> AdvancedProcessedResult {
        guard !paths.isEmpty, let reference else { return .init(paths: paths, errors: errors, cancelled: cancelled, reference: reference) }
        do {
            let statistics = try queue.sync {
                try autoreleasepool {
                    if permanent { return try TrashInspectionStore(reference: reference, readOnly: false).removeProcessedPaths(paths) }
                    return try ScanResultStore(reference: reference, readOnly: false).removeProcessedPaths(paths)
                }
            }
            return .init(paths: paths, errors: errors, cancelled: cancelled, reference: reference, statistics: statistics)
        } catch {
            return .init(paths: paths, errors: errors, cancelled: cancelled, reference: reference,
                         indexError: "文件处理已成功，但剩余结果索引未能刷新。暂不能继续处理，请重新扫描后再操作：" + error.localizedDescription)
        }
    }
    private func applyProcessed(_ result: AdvancedProcessedResult, permanent: Bool) {
        guard !result.paths.isEmpty, !discardOperationResult else { return }
        if permanent {
            guard var metadata = trashReport, metadata.resultStore == result.reference else { return }
            if let statistics = result.statistics {
                metadata.totalCount = statistics.totalCount; metadata.totalBytes = statistics.totalBytes; metadata.processableCount = statistics.processableCount
                trashIndexError = nil
            } else if result.reference == nil {
                fallbackTrash.removeAll { item in result.paths.contains { FileSafety.contains($0, item.path) } }
                metadata.totalCount = fallbackTrash.count; metadata.totalBytes = fallbackTrash.reduce(0) { $0 + $1.bytes }
                metadata.processableCount = fallbackTrash.filter(\.canPermanentlyDelete).count
            }
            trashReport = metadata
            if let error = result.indexError { trashIndexError = error }
        } else {
            guard var metadata = report, metadata.resultStore == result.reference else { return }
            if let statistics = result.statistics {
                metadata.totalCount = statistics.totalCount; metadata.totalBytes = statistics.totalBytes; metadata.processableCount = statistics.processableCount
                candidateIndexError = nil
            } else if result.reference == nil {
                fallbackCandidates.removeAll { item in result.paths.contains { FileSafety.contains($0, item.path) } }
                metadata.totalCount = fallbackCandidates.count; metadata.totalBytes = fallbackCandidates.reduce(0) { $0 + $1.bytes }
                metadata.processableCount = fallbackCandidates.filter(\.canTrash).count
            }
            report = metadata
            if let error = result.indexError { candidateIndexError = error }
        }
        if (permanent && tab == .trash) || (!permanent && tab == .candidates) {
            page = min(page, pageCount - 1); loadPage()
        }
    }
    private func start(_ title: String, clearResults: Bool = false, work: @escaping @Sendable (MalwareCancellation, AdvancedProgressMailbox) -> AdvancedResult) {
        guard !busy else { return }
        let cancellation = MalwareCancellation(), mailbox = AdvancedProgressMailbox(), receiver = AdvancedPanelReference(self)
        let center = taskCenter
        guard let id = center.begin(title, destination: .advancedCleanup, cancel: { [weak self] in self?.cancel(); cancellation.cancel() }) else {
            message = "另一项检测或处理仍在运行，请等待完成或取消当前全局任务。"; return
        }
        if clearResults {
            pageToken?.cancel(); pageTask?.cancel(); pageID = UUID(); candidatePage = []; trashPage = []; pageLoading = false
        }
        let queue = resultQueue
        discardOperationResult = false; confirmation = nil
        operationID = id; operationTab = tab; token = cancellation; busyTitle = title; errors = []; progressCount = 0; progressPath = ""; selected = []
        activeMailbox = mailbox
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
                guard let self, self.operationID == id else { break }
                let latest = mailbox.snapshot()
                center.update(id, count: latest.0, path: latest.1, phase: self.busyTitle)
                if self.presentationActive { self.progressCount = latest.0; self.progressPath = latest.1 }
            }
        }
        operation = Task {
            let result = await Task.detached(priority: .utility) { work(cancellation, mailbox) }.value
            mailbox.close()
            defer { center.finish(id) }
            guard let target = receiver.value, target.operationID == id else {
                let reference: ScanResultReference?
                switch result { case .cleanup(let value): reference = value.resultStore; case .trash(let value): reference = value.resultStore; default: reference = nil }
                if let reference { queue.async { try? ScanResultStore.remove(reference) } }
                return
            }
            if target.discardOperationResult {
                let reference: ScanResultReference?
                switch result { case .cleanup(let value): reference = value.resultStore; case .trash(let value): reference = value.resultStore; default: reference = nil }
                if let reference { queue.async { try? ScanResultStore.remove(reference) } }
                switch result {
                case .cleanup, .trash: target.finishOperation(id); return
                default: break // Preserve the actual outcome of a mutation already acknowledged by the worker.
                }
            }
            switch result {
            case .cleanup(let report):
                if report.visitedFiles == 0, report.resultStore == nil, report.warnings.contains(where: { $0.contains("另一个重型操作") }) {
                    target.message = report.warnings.joined(separator: "\n"); target.loadPage(); break
                }
                target.invalidateCandidates(); var metadata = report; metadata.items = []
                target.report = metadata; target.fallbackCandidates = report.resultStore == nil ? report.items : []
                if report.resultStore == nil { target.report?.totalCount = report.items.count }
                target.progressCount = report.visitedFiles
                target.loadPage()
            case .trash(let report):
                if report.visitedFiles == 0, report.resultStore == nil, report.warnings.contains(where: { $0.contains("另一个重型操作") }) {
                    target.message = report.warnings.joined(separator: "\n"); target.loadPage(); break
                }
                target.invalidateTrash(); var metadata = report; metadata.items = []
                target.trashReport = metadata; target.fallbackTrash = report.resultStore == nil ? report.items : []
                if report.resultStore == nil { target.trashReport?.totalCount = report.items.count }
                target.progressCount = report.visitedFiles
                target.loadPage()
            case .deleted(let result):
                target.errors = result.errors + (result.indexError.map { [$0] } ?? [])
                target.progressCount = result.paths.count
                target.applyProcessed(result, permanent: true)
                let scope = target.discardOperationResult ? "原扫描范围已因忽略规则变更失效。" : "其余扫描结果保留。"
                target.message = "已永久删除并回读确认\(result.paths.count)项；" + scope + (result.cancelled ? "未完成的处理已取消。" : "") + (result.errors.isEmpty ? "" : "失败项目仍保留，具体原因已列在面板中。") + (result.indexError.map { "\n" + $0 } ?? "")
            case .moved(let result):
                target.errors = result.errors + (result.indexError.map { [$0] } ?? [])
                target.progressCount = result.paths.count
                target.applyProcessed(result, permanent: false)
                let scope = target.discardOperationResult ? "原扫描范围已因忽略规则变更失效。" : "其余扫描结果保留。"
                target.message = "已移入系统废纸篓\(result.paths.count)项；" + scope + (result.cancelled ? "未完成的处理已取消。" : "") + (result.errors.isEmpty ? "" : "失败项目仍保留，具体原因已列在面板中。") + (result.indexError.map { "\n" + $0 } ?? "")
            case .versions(let versions, let records): target.versions = versions; target.archives = records.filter { $0.documentPath == target.document?.path }; target.page = 0
            case .versionAction(let versions, let records, let summary): target.versions = versions; target.archives = records.filter { $0.documentPath == target.document?.path }; target.message = summary; target.page = 0
            case .failure(let error): target.errors = [error]; target.message = error
            }
            center.update(id, count: target.progressCount, path: target.progressPath, phase: title)
            target.finishOperation(id)
            if target.page >= target.pageCount { target.page = max(0, target.pageCount - 1) }
        }
    }
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        busyTitle = nil; token = nil; operationID = nil; operationTab = nil; poll?.cancel(); poll = nil; operation = nil; activeMailbox = nil; discardOperationResult = false
    }
    func cancel() {
        if let id = operationID { taskCenter.markCancelling(id) }
        token?.cancel(); if busy { busyTitle = "正在取消，当前文件操作结束后停止" }
    }
    func ignoreRulesChanged() {
        if busy, operationTab == .candidates { discardOperationResult = true; token?.cancel(); busyTitle = "忽略规则已更新，正在取消旧范围检查" }
        invalidateCandidates()
    }
    func stopOnDisappear() {
        presentationActive = false; selected = []; confirmation = nil; permanentPhrase = ""
        pageToken?.cancel(); pageToken = nil; pageTask?.cancel(); pageTask = nil; pageID = UUID()
        candidatePage = []; trashPage = []; pageLoading = false
    }
    func resumePresentation() {
        presentationActive = true
        if let latest = activeMailbox?.snapshot() { progressCount = latest.0; progressPath = latest.1 }
        if !pageLoading { loadPage() }
    }
}

@MainActor
struct AdvancedCleanupView: View {
    @ObservedObject private var state: AdvancedCleanupState
    @ObservedObject private var tasks: DetectionTaskCenter
    init(registry: FeatureStateRegistry? = nil) {
        let registry = registry ?? .shared
        _state = ObservedObject(wrappedValue: registry.retain("advancedCleanup") { AdvancedCleanupState(taskCenter: registry.tasks) })
        _tasks = ObservedObject(wrappedValue: registry.tasks)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "AIYOUClean · inspect before changing", title: "高级清理", detail: "开发与AI缓存、损坏偏好候选、iOS备份及各卷废纸篓。历史版本先归档，所有处理都由你逐项确认。")
                Picker("工具", selection: $state.tab) { ForEach(AdvancedTab.allCases) { tab in Text(tab.rawValue).tag(tab) } }
                    .pickerStyle(.segmented).disabled(state.busy)
                controls
                if let title = state.busyTitle {
                    HStack {
                        ProgressView().controlSize(.small); Text(title).font(.callout)
                        Spacer(); Button("取消") { state.cancel() }
                    }
                    Text("已检查/处理\(state.progressCount)项 · \(state.progressPath)")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(advancedSecondary)
                }
                if !state.errors.isEmpty { warnings(state.errors, title: "操作错误") }
                if let error = state.processingIndexError { Text(error).font(.callout).foregroundStyle(Color.orange).textSelection(.enabled) }
                switch state.tab {
                case .candidates: candidates
                case .trash: trashItems
                case .versions: documentVersions
                }
                if state.pageLoading { ProgressView("正在读取磁盘分页…") }
                if let error = state.pageError { Text(error).font(.callout).foregroundStyle(Color.orange) }
                if state.pageCount > 1 {
                    HStack {
                        Button("上一页") { state.previousPage() }.disabled(state.busy || state.pageLoading || state.page == 0)
                        Text("第\(state.page + 1)/\(state.pageCount)页 · 每页200项").font(.caption).foregroundStyle(advancedSecondary)
                        Button("下一页") { state.nextPage() }.disabled(state.busy || state.pageLoading || state.page + 1 >= state.pageCount)
                    }
                }
                Text(state.tab == .versions ? "只处理明确选择文档的本地历史版本；当前文档内容不会被覆盖。" : "持续扫描到完成，全部结果写入磁盘，每页只读取200项；换页会清空选择。链接、占位云文件及未完整检查的目录不可处理，取消及真实读取错误会保留不完整状态。")
                    .font(.caption).foregroundStyle(advancedSecondary).fixedSize(horizontal: false, vertical: true)
            }.padding(30)
        }
        .onChange(of: state.tab) { _ in state.switchContent() }
        .onChange(of: state.category) { _ in state.switchCategory() }
        .onAppear { state.resumePresentation() }
        .onDisappear { state.stopOnDisappear() }
        .sheet(item: $state.confirmation) { pending in confirmation(pending) }
        .alert("高级清理结果", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("好") { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
    private var controls: some View {
        Surface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if state.tab == .candidates {
                        Picker("类型", selection: $state.category) { ForEach(ExtendedCleanupCategory.allCases) { category in Text(category.title).tag(category) } }.frame(maxWidth: 350).disabled(state.busy)
                    }
                    if state.tab == .versions { Button("选择文档…") { state.chooseDocument() }.disabled(state.busy || tasks.isBusy) }
                    Button(state.tab == .trash ? "清点废纸篓" : (state.tab == .versions ? "读取历史" : "扫描候选")) { state.scan() }
                        .buttonStyle(.borderedProminent).tint(advancedAccent).disabled(state.busy || tasks.isBusy || (state.tab == .versions && state.document == nil))
                    Spacer()
                    if state.tab != .versions {
                        Text("已选\(state.selected.count)项").font(.caption)
                        Button(state.tab == .trash ? "永久删除所选…" : "移入废纸篓…") { state.requestProcessing() }.disabled(state.busy || tasks.isBusy || state.pageLoading || state.processingIndexError != nil || state.selected.isEmpty)
                    }
                }
                Text(explanation).font(.callout).foregroundStyle(state.tab == .trash ? Color.orange : advancedSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var explanation: String {
        switch state.tab {
        case .candidates:
            if state.category == .iOSBackups { return "这是设备完整备份，不是缓存。处理会移入系统废纸篓并保留恢复记录；保留在废纸篓时不会真正释放这些占用。" }
            if state.category == .brokenPreferences { return "只列系统plist解析失败的候选；不判断业务配置正确与否。移走后应用偏好可能重置。" }
            return "缓存和模型可能需要重新生成或下载。扫描只读，默认不选中任何项目；移入废纸篓保留恢复路径。"
        case .trash: return "永久删除不可恢复。只清点当前用户废纸篓及已挂载卷/.Trashes/UID；必须确认具体路径并输入“永久删除”，不会一键清空根目录。"
        case .versions: return "仅处理所选文档的本地NSFileVersion历史。先将内容备份到AIYOUClean归档再移除；恢复只新增历史版本，不覆盖当前文档。"
        }
    }
    private var candidates: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = state.report {
                Text("\(report.totalCount)个候选 · \(Format.bytes(report.totalBytes)) · 访问\(report.visitedFiles)项" + (report.truncated || report.cancelled ? " · 结果不完整" : ""))
                    .font(.headline).foregroundStyle(report.truncated || report.cancelled ? Color.orange : Color.primary)
                if !report.warnings.isEmpty { warnings(report.warnings, title: "扫描提示") }
                LazyVStack(spacing: 10) {
                    ForEach(state.candidatePage) { item in
                        Surface {
                            HStack(alignment: .top, spacing: 12) {
                                selection(item.path, enabled: item.canTrash && !state.movedPaths.contains(item.path))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.headline)
                                    Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text("\(item.category) · \(item.detail)").font(.caption).foregroundStyle(advancedSecondary)
                                    if state.movedPaths.contains(item.path) { Text("已移入废纸篓").font(.caption).foregroundStyle(.green) }
                                }
                                Spacer(); Text(Format.bytes(item.bytes)).font(.callout.monospaced())
                            }
                        }
                    }
                }
            } else { Text("点击扫描，读取当前类型的候选清单。").font(.callout).foregroundStyle(advancedSecondary) }
        }
    }
    private var trashItems: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = state.trashReport {
                Text("\(report.totalCount)个废纸篓项目 · \(Format.bytes(report.totalBytes)) · 访问\(report.visitedFiles)项" + (report.truncated || report.cancelled ? " · 清点不完整" : "")).font(.headline)
                if !report.warnings.isEmpty { warnings(report.warnings, title: "清点提示") }
                LazyVStack(spacing: 10) {
                    ForEach(state.trashPage) { item in
                        Surface {
                            HStack(alignment: .top, spacing: 12) {
                                selection(item.path, enabled: item.canPermanentlyDelete)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.headline)
                                    Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(item.canPermanentlyDelete ? "已完整清点，仍需逐项确认" : "未完整清点/含链接，不可永久删除").font(.caption).foregroundStyle(item.canPermanentlyDelete ? advancedSecondary : .orange)
                                }
                                Spacer(); Text(Format.bytes(item.bytes)).font(.callout.monospaced())
                            }
                        }
                    }
                }
            } else { Text("点击清点后才读取废纸篓内容；不会自动删除。").font(.callout).foregroundStyle(advancedSecondary) }
        }
    }
    private var documentVersions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let document = state.document { Text(document.path).font(.caption.monospaced()).textSelection(.enabled) }
            let start = state.page * 200
            let localVersions = Array(state.versions.dropFirst(start).prefix(200))
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(localVersions) { version in
                    Surface {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(version.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "时间未知").font(.headline)
                                Text(version.hasLocalContents ? "本地历史版本" : "非本地版本，不下载或移除").font(.caption).foregroundStyle(advancedSecondary)
                            }
                            Spacer(); Button("先归档再移除…") { state.requestArchive(version) }.disabled(state.busy || tasks.isBusy || !version.hasLocalContents)
                        }
                    }
                }
                let archiveStart = max(0, start - state.versions.count)
                let remaining = max(0, 200 - localVersions.count)
                ForEach(Array(state.archives.dropFirst(archiveStart).prefix(remaining))) { record in
                    Surface {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("AIYOUClean归档 · \(record.date.formatted(date: .numeric, time: .shortened))").font(.headline)
                                Text(record.documentPath).font(.caption.monospaced()).textSelection(.enabled)
                                Text("\(Format.bytes(record.bytes)) · " + (record.restoredAsHistory ? "已新增为历史版本" : (record.versionRemoved ? "系统历史版本已移除" : "备份已存在，移除结果未确认"))).font(.caption).foregroundStyle(advancedSecondary)
                            }
                            Spacer(); Button("恢复为历史版本…") { state.requestRestore(record) }.disabled(state.busy || tasks.isBusy || record.restoredAsHistory)
                        }
                    }
                }
            }
            if state.document != nil && state.versions.isEmpty && state.archives.isEmpty && !state.busy { Text("未发现本地历史版本或归档。当前文档仍保持原样。").font(.callout).foregroundStyle(advancedSecondary) }
        }
    }
    private func selection(_ id: String, enabled: Bool) -> some View {
        Toggle("选择", isOn: Binding(get: { state.selected.contains(id) }, set: { checked in if checked { state.selected.insert(id) } else { state.selected.remove(id) } }))
            .labelsHidden().disabled(state.busy || state.pageLoading || state.processingIndexError != nil || !enabled)
    }
    private func warnings(_ values: [String], title: String) -> some View {
        DisclosureGroup("\(title)（\(values.count)条）") {
            LazyVStack(alignment: .leading, spacing: 7) { ForEach(Array(values.prefix(101).enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).textSelection(.enabled) } }.padding(.top, 8)
        }.foregroundStyle(.orange).padding(14).background(Color.orange.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func confirmation(_ pending: AdvancedConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(confirmationTitle(pending)).font(.title2.weight(.semibold))
            switch pending.action {
            case .trash(let items):
                Text("以下具体项目将移入系统废纸篓，保留清理记录。恢复请使用清理历史；移入废纸篓不等于永久释放占用。").font(.callout).foregroundStyle(advancedSecondary)
                paths(items.map(\.path))
            case .permanent(let items):
                Text("以下项目及目录内容将永久移除，无法从AIYOUClean恢复。删除前会重新核对边界、身份和内容指纹；变化或包含链接时拒绝处理。").font(.callout).foregroundStyle(.orange)
                paths(items.map(\.path))
                TextField("输入“永久删除”", text: $state.permanentPhrase).textFieldStyle(.roundedBorder)
            case .archive(let version):
                Text(version.documentPath).font(.caption.monospaced()).textSelection(.enabled)
                Text("历史版本时间：\(version.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "未知")")
                Text("先复制此历史内容到AIYOUClean私有归档并写收据，再移除这个系统历史版本。当前文档内容不会被替换。").font(.callout).foregroundStyle(advancedSecondary)
            case .restore(let record):
                Text(record.documentPath).font(.caption.monospaced()).textSelection(.enabled)
                Text(record.backupPath).font(.caption.monospaced()).foregroundStyle(advancedSecondary).textSelection(.enabled)
                Text("校验归档内容后，使用系统API新增为历史版本，不覆盖当前文档。").font(.callout).foregroundStyle(advancedSecondary)
            }
            HStack {
                Button("取消") { state.confirmation = nil }.keyboardShortcut(.cancelAction)
                Spacer(); Button("确认这次操作") { state.perform(pending) }.buttonStyle(.borderedProminent).tint(advancedAccent).disabled(state.busy || tasks.isBusy || (isPermanent(pending) && state.permanentPhrase != "永久删除"))
            }
        }.padding(26).frame(width: 650)
    }
    private func paths(_ values: [String]) -> some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 9) { ForEach(values, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: 280)
    }
    private func isPermanent(_ pending: AdvancedConfirmation) -> Bool { if case .permanent = pending.action { return true }; return false }
    private func confirmationTitle(_ pending: AdvancedConfirmation) -> String {
        switch pending.action { case .trash(let items): return "确认移入废纸篓\(items.count)项"; case .permanent(let items): return "确认永久删除\(items.count)项"; case .archive: return "确认归档并移除这个历史版本"; case .restore: return "确认新增为历史版本" }
    }
}
