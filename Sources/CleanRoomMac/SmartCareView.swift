import SwiftUI
import AppKit
import Combine
import CleanRoomCore

private let smartAccent = Color(red: 0.61, green: 0.49, blue: 1)
private let smartSecondary = Color(red: 0.65, green: 0.68, blue: 0.78)
private final class SmartCareMailbox: @unchecked Sendable {
    private let lock = NSLock(); private var latest: SmartCareProgress?; private var open = true
    func publish(_ progress: SmartCareProgress) { lock.lock(); defer { lock.unlock() }; if open { latest = progress } }
    func take() -> SmartCareProgress? { lock.lock(); defer { lock.unlock() }; let value = latest; latest = nil; return value }
    func close() { lock.lock(); open = false; latest = nil; lock.unlock() }
}
private struct SmartCareConfirmation: Identifiable {
    let id = UUID(); let items: [ScanItem]; let ignoreRules: [String]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}
private enum SmartCareResultMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case processable, readOnly, issues
    var id: String { rawValue }
    var title: String {
        switch self { case .processable: return "可处理"; case .readOnly: return "只读发现"; case .issues: return "访问问题" }
    }
}
private enum SmartCareActionResult: Sendable { case processed(TrashOutcome), failed(String), policyChanged(String) }
private struct SmartCareCleanupUpdate: Sendable {
    var report: SmartCareReport
    var counts: [SmartCareResultMode: Int] = [:]
    var errors: [String] = []
}
private enum SmartCarePageResult: Sendable { case loaded([ScanItem], Int), failed(String) }
private final class SmartCareStateReference: @unchecked Sendable {
    @MainActor weak var value: SmartCareViewState?
    @MainActor init(_ value: SmartCareViewState) { self.value = value }
}
@MainActor
private final class SmartCareViewState: ObservableObject {
    @Published var includeApplications = true
    @Published private(set) var scanScope: SmartCareScanScope = .allLocalDisks
    @Published private(set) var roots: [URL] = []
    @Published private(set) var report: SmartCareReport?
    @Published private(set) var phase: String?
    @Published private(set) var progress: SmartCareProgress?
    @Published private(set) var errors: [String] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var resultMode: SmartCareResultMode = .processable
    @Published private(set) var page = 0
    @Published private(set) var pageItems: [ScanItem] = []
    @Published private(set) var pageItemCount = 0
    @Published private(set) var pageLoading = false
    @Published private(set) var pageError: String?
    @Published private(set) var resolvedCounts: [SmartCareResultMode: Int] = [:]
    @Published var confirmation: SmartCareConfirmation?
    @Published var message: String?
    let pageSize = 200
    private let taskCenter: DetectionTaskCenter
    private let home: URL
    private let trashManagerFactory: @Sendable () -> TrashManager
    private var detectionID: UUID?
    private var ignoreRuleChanges: AnyCancellable?
    private var latestProgress: SmartCareProgress?
    private var token: MalwareCancellation?
    private var mailbox: SmartCareMailbox?
    private var task: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var pageCancellation: MalwareCancellation?
    private var poll: Task<Void, Never>?
    private var requestID: UUID?
    private var pageRequestID: UUID?
    private var policyGeneration = 0
    private var presentationActive = true
    init(taskCenter: DetectionTaskCenter? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser, trashManagerFactory: (@Sendable () -> TrashManager)? = nil) {
        self.taskCenter = taskCenter ?? .shared
        let home = home.standardizedFileURL
        self.home = home
        self.trashManagerFactory = trashManagerFactory ?? { TrashManager(home: home) }
        let receiver = SmartCareStateReference(self)
        ignoreRuleChanges = NotificationCenter.default.publisher(for: IgnoreRuleStore.didChangeNotification).sink { note in
            guard note.object as? String == home.path else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { receiver.value?.ignoreRulesChanged() }
            } else {
                DispatchQueue.main.async { receiver.value?.ignoreRulesChanged() }
            }
        }
    }
    var busy: Bool { phase != nil || pageLoading }
    var canStartScan: Bool { !busy && !taskCenter.isBusy && (scanScope != .selectedFolders || !roots.isEmpty) }
    var pageCount: Int { max(1, (pageItemCount + pageSize - 1) / pageSize) }
    var selectedItems: [ScanItem] { resultMode == .processable ? pageItems.filter { selected.contains($0.path) && $0.canTrash } : [] }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    func resume() {
        presentationActive = true
        progress = latestProgress
        if let latestProgress, let detectionID, requestID != nil, token?.isCancelled == false {
            let stage = progressPhase(latestProgress)
            if phase != stage { phase = stage }
            taskCenter.update(detectionID, count: latestProgress.visitedFiles, path: latestProgress.path, phase: stage)
        }
        if phase == nil, report != nil { loadPage(page) }
    }
    private func progressPhase(_ value: SmartCareProgress) -> String {
        value.phase ?? ("检查" + value.module.title)
    }
    private func cancelPage() {
        pageRequestID = nil; pageCancellation?.cancel(); pageCancellation = nil
        pageTask?.cancel(); pageTask = nil; pageLoading = false
    }
    private func releaseReport() {
        cancelPage()
        let references = Self.ownedReferences(report)
        report = nil; resultMode = .processable; selected = []; page = 0; pageItems = []; pageItemCount = 0; pageError = nil; resolvedCounts = [:]; confirmation = nil
        Self.dispose(references)
    }
    private nonisolated static func ownedReferences(_ report: SmartCareReport?) -> [ScanResultReference] {
        guard let report else { return [] }
        var references: [ScanResultReference] = []
        for reference in [report.resultStore, report.readOnlyStore, report.diskCoverage?.issueStore].compactMap({ $0 }) {
            if !references.contains(where: { $0.path == reference.path && $0.sessionID == reference.sessionID }) { references.append(reference) }
        }
        return references
    }
    private nonisolated static func dispose(_ references: [ScanResultReference]) {
        guard !references.isEmpty else { return }
        Task.detached(priority: .utility) { for reference in references { try? ScanResultStore.remove(reference) } }
    }
    func invalidateForOptions() { guard !busy else { return }; releaseReport() }
    func setScanScope(_ value: SmartCareScanScope) {
        guard !busy, value != .localMaintenance, value != scanScope else { return }
        releaseReport(); scanScope = value
    }
    func chooseRoots() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "选择要完整检查的文件夹；取消不会改变当前范围。"; panel.prompt = "检查这些文件夹"
        if panel.runModal() == .OK, !panel.urls.isEmpty { releaseReport(); roots = panel.urls; scanScope = .selectedFolders }
    }
    func modeCount(_ mode: SmartCareResultMode) -> Int {
        guard let report else { return 0 }
        if let count = resolvedCounts[mode] { return count }
        switch mode {
        case .processable: return report.totalItemCount
        case .readOnly: return report.readOnlyStoredCount
        case .issues: return report.diskCoverage?.issueCount ?? 0
        }
    }
    func setResultMode(_ mode: SmartCareResultMode) {
        guard phase == nil, resultMode != mode else { return }
        cancelPage(); selected = []; confirmation = nil; resultMode = mode
        page = 0; pageItemCount = modeCount(mode); pageItems = []; pageError = nil
        loadPage(0)
    }
    func ignoreRulesChanged() {
        policyGeneration += 1
        cancelCurrentTask(); releaseReport()
        message = "忽略清单已更新，旧结果已失效。下次扫描使用新清单。"
    }
    func scan() {
        guard !busy, presentationActive, scanScope != .selectedFolders || !roots.isEmpty else { return }
        guard let ticket = taskCenter.begin("智能检查", destination: .smartCare, cancel: { [weak self] in self?.cancel() }) else {
            message = "已有检测正在进行；请从任务栏返回查看或取消后再开始。"
            return
        }
        detectionID = ticket
        let options = SmartCareOptions(home: home, includeApplications: includeApplications, scanScope: scanScope, roots: scanScope == .selectedFolders ? roots : [])
        let id = UUID(), cancellation = MalwareCancellation(), slot = SmartCareMailbox(), receiver = SmartCareStateReference(self), generation = policyGeneration
        let center = taskCenter
        releaseReport()
        requestID = id; token = cancellation; mailbox = slot; phase = scanScope == .allLocalDisks ? "正在检查启动磁盘及本地挂载盘" : "正在检查所选文件夹"; errors = []; progress = nil; latestProgress = nil
        poll = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let target = receiver.value, target.requestID == id, target.policyGeneration == generation, !cancellation.isCancelled else { return }
                if let value = slot.take() {
                    target.latestProgress = value
                    let stage = target.progressPhase(value)
                    if target.phase != stage { target.phase = stage }
                    if target.presentationActive { target.progress = value }
                    center.update(ticket, count: value.visitedFiles, path: value.path, phase: stage)
                }
            }
        }
        task = Task {
            let result = await Task.detached(priority: .utility) { SmartCareService().scan(options: options, cancellation: cancellation, progress: { slot.publish($0) }) }.value
            slot.close()
            defer { center.finish(ticket) }
            guard let target = receiver.value, target.requestID == id else { Self.dispose(Self.ownedReferences(result)); return }
            let acceptsResult = target.policyGeneration == generation
            center.update(ticket, count: result.visitedFiles, path: result.cancelled ? "检测已取消" : (result.invalidated ? "结果已失效" : "检测结果已保存"))
            target.finish(id)
            if acceptsResult {
                target.report = result; target.resultMode = .processable; target.pageItemCount = result.totalItemCount
                if target.presentationActive { target.loadPage(0) }
            } else { Self.dispose(Self.ownedReferences(result)) }
        }
    }
    func cancel() {
        if let detectionID { taskCenter.markCancelling(detectionID) }
        token?.cancel(); mailbox?.close(); poll?.cancel()
        if phase != nil { phase = "正在取消，等待当前操作结束" }
    }
    func cancelCurrentTask() { cancel() }
    func stopOnDisappear() {
        presentationActive = false
        selected = []; confirmation = nil; cancelPage(); pageItems = []
    }
    func toggle(_ item: ScanItem) {
        guard resultMode == .processable, !busy, !taskCenter.isBusy, report?.invalidated == false, item.canTrash, pageItems.contains(where: { $0.id == item.id }) else { return }
        if selected.contains(item.path) { selected.remove(item.path) } else { selected.insert(item.path) }
    }
    func selectPage() { guard resultMode == .processable, !busy, !taskCenter.isBusy, report?.invalidated == false else { return }; selected = Set(pageItems.filter(\.canTrash).map(\.path)) }
    func clearSelection() { selected = []; confirmation = nil }
    func previousPage() { guard !busy, page > 0 else { return }; loadPage(page - 1) }
    func nextPage() { guard !busy, page + 1 < pageCount else { return }; loadPage(page + 1) }
    private func loadPage(_ index: Int) {
        guard phase == nil, let report, !report.invalidated, presentationActive else { return }
        selected = []; confirmation = nil; pageItems = []; pageLoading = true; pageError = nil
        let mode = resultMode
        let reference: ScanResultReference?
        switch mode { case .processable: reference = report.resultStore; case .readOnly: reference = report.readOnlyStore; case .issues: reference = report.diskCoverage?.issueStore }
        let id = UUID(), receiver = SmartCareStateReference(self), cancellation = MalwareCancellation()
        let fallback = mode == .processable ? report.items : [], expectedCount = modeCount(mode)
        let offset = index * pageSize, pageSize = pageSize
        pageRequestID = id; pageCancellation?.cancel(); pageCancellation = cancellation; pageTask?.cancel()
        pageTask = Task {
            let value = await Task.detached(priority: .utility) { () -> SmartCarePageResult in
                do {
                    if let reference {
                        let source = try ScanResultStore(reference: reference)
                        let result = try source.page(offset: offset, limit: pageSize, processableOnly: mode == .processable, isCancelled: { cancellation.isCancelled })
                        return .loaded(result.items, result.filteredCount)
                    }
                    if mode != .processable && expectedCount > 0 { return .failed("此类索引暂不可读取；空页不代表没有发现。请查看扫描提示或重新检查。") }
                    return .loaded(Array(fallback.dropFirst(offset).prefix(pageSize)), fallback.count)
                } catch { return .failed(error.localizedDescription) }
            }.value
            guard let target = receiver.value, target.pageRequestID == id, target.presentationActive, target.resultMode == mode else { return }
            target.pageLoading = false; target.pageTask = nil; target.pageRequestID = nil; target.pageCancellation = nil
            switch value {
            case .loaded(let items, let count): target.pageItems = items; target.pageItemCount = count; target.resolvedCounts[mode] = count; target.page = index
            case .failed(let reason): target.pageError = reason
            }
        }
    }
    func requestTrash() {
        guard resultMode == .processable, !busy, !taskCenter.isBusy, let report, !report.invalidated, !selectedItems.isEmpty else { return }
        confirmation = SmartCareConfirmation(items: selectedItems, ignoreRules: report.appliedIgnoreRules)
    }
    func trash(_ pending: SmartCareConfirmation) {
        guard resultMode == .processable, !busy, presentationActive, let snapshot = report, !snapshot.invalidated, !pending.items.isEmpty, pending.items.count <= pageSize else { return }
        let cancellation = MalwareCancellation()
        guard let ticket = taskCenter.begin("智能检查：清理所选", destination: .smartCare, cancel: { [weak self] in cancellation.cancel(); self?.cancel() }) else {
            message = "已有检测或处理正在进行；请等待任务结束或取消后再处理。"
            return
        }
        detectionID = ticket
        confirmation = nil
        let id = UUID(), receiver = SmartCareStateReference(self), center = taskCenter
        let generation = policyGeneration, home = home, makeManager = trashManagerFactory, previewLimit = pageSize
        requestID = id; token = cancellation; phase = "移入系统废纸篓"; errors = []; progress = nil; latestProgress = nil
        center.update(ticket, count: 0, path: "正在核对并处理\(pending.items.count)个已确认项目", phase: phase)
        task = Task {
            let result = await Task.detached(priority: .utility) { () -> SmartCareActionResult in
                do {
                    guard try IgnoreRuleStore(home: home).load() == pending.ignoreRules else { return .policyChanged("忽略清单已改变，未按旧结果处理；请重新扫描。") }
                    return .processed(makeManager().trash(pending.items, isCancelled: { cancellation.isCancelled }))
                } catch { return .failed(error.localizedDescription) }
            }.value
            defer { center.finish(ticket) }
            guard let target = receiver.value, target.requestID == id else { return }
            target.selected = []; target.confirmation = nil
            var reloadResults = false
            switch result {
            case .processed(let outcome):
                target.errors = Array(outcome.errors.prefix(previewLimit))
                var receipt = "已移入系统废纸篓\(outcome.records.count)项；可在清理历史中核对恢复记录。" + (cancellation.isCancelled ? "其余处理已取消。" : "") + (outcome.errors.isEmpty ? "" : "具体失败原因已列出。")
                center.update(ticket, count: outcome.records.count, path: "已移入系统废纸篓\(outcome.records.count)项")
                if !outcome.records.isEmpty, target.acceptsCleanup(snapshot, generation: generation) {
                    target.phase = "更新已检查内容"
                    center.update(ticket, count: outcome.records.count, path: "保留未成功处理的项目并更新剩余列表", phase: target.phase)
                    let update = await Task.detached(priority: .utility) {
                        Self.reconcileCleanup(snapshot, pendingItems: pending.items, outcome: outcome, previewLimit: previewLimit)
                    }.value
                    guard target.requestID == id else { return }
                    if target.acceptsCleanup(snapshot, generation: generation) {
                        target.report = update.report
                        for (mode, count) in update.counts { target.resolvedCounts[mode] = count }
                        target.pageItemCount = target.modeCount(target.resultMode)
                        target.page = min(target.page, target.pageCount - 1)
                        target.errors = Array((update.errors + outcome.errors).prefix(previewLimit + 8))
                        receipt += update.errors.isEmpty ? "未成功处理的项目和其他已检查内容继续保留。" : "列表更新失败的索引已保留，部分已处理项目可能仍显示；具体原因已列出。"
                        reloadResults = true
                    } else { receipt += "忽略清单已更新，旧结果继续保持失效。" }
                } else if target.acceptsCleanup(snapshot, generation: generation) {
                    receipt += "未成功处理的项目和已检查内容均已保留。"
                } else { receipt += "忽略清单已更新，旧结果继续保持失效。" }
                target.message = receipt
                center.update(ticket, count: outcome.records.count, path: "已移入系统废纸篓\(outcome.records.count)项；查看保留的检查结果", phase: "清理处理已结束")
            case .failed(let reason):
                target.errors = [reason]; target.message = reason
                center.update(ticket, count: 0, path: "本次处理未完成，请返回查看原因")
            case .policyChanged(let reason):
                if target.policyGeneration == generation { target.ignoreRulesChanged() }
                target.errors = [reason]; target.message = reason
                center.update(ticket, count: 0, path: "忽略清单已改变，未按旧结果处理")
            }
            target.finish(id)
            if target.presentationActive, target.report != nil, reloadResults || target.pageItems.isEmpty { target.loadPage(target.page) }
        }
    }
    private func acceptsCleanup(_ snapshot: SmartCareReport, generation: Int) -> Bool {
        guard policyGeneration == generation, let report, !report.invalidated else { return false }
        return report.startedAt == snapshot.startedAt && report.finishedAt == snapshot.finishedAt && Self.ownedReferences(report) == Self.ownedReferences(snapshot)
    }
    private nonisolated static func normalizedCleanupPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    private nonisolated static func reconcileCleanup(_ snapshot: SmartCareReport, pendingItems: [ScanItem], outcome: TrashOutcome, previewLimit: Int) -> SmartCareCleanupUpdate {
        var update = SmartCareCleanupUpdate(report: snapshot)
        // A confirmation contains at most one 200-item page. Receipt paths never
        // authorize pruning paths that were absent from that confirmation.
        let successful = Set(outcome.records.compactMap { normalizedCleanupPath($0.originalPath) })
        var paths: [String] = [], matched = Set<String>()
        for item in pendingItems {
            guard let normalized = normalizedCleanupPath(item.path), successful.contains(normalized), !matched.contains(normalized) else { continue }
            matched.insert(normalized); paths.append(item.path)
        }
        if !successful.isSubset(of: matched) { update.errors.append("部分成功回执未匹配已确认的原扫描路径；未按这些回执删除列表项目，原索引已保留。") }
        guard !paths.isEmpty else {
            if update.errors.isEmpty { update.errors.append("成功回执未匹配已确认的原扫描路径，原索引已保留。") }
            return update
        }
        let normalizedPaths = paths.compactMap(normalizedCleanupPath)
        func remainingPreview(_ items: [ScanItem]) -> [ScanItem] {
            items.filter { item in
                guard let path = normalizedCleanupPath(item.path) else { return true }
                return !normalizedPaths.contains { FileSafety.contains($0, path) }
            }
        }
        if let reference = snapshot.resultStore {
            do {
                let store = try ScanResultStore(reference: reference, readOnly: false)
                let statistics = try store.removeProcessedPaths(paths)
                update.report.totalItemCount = statistics.processableCount
                update.report.totalProcessableBytes = statistics.processableBytes
                update.report.items = remainingPreview(snapshot.items)
                update.counts[.processable] = statistics.processableCount
                do { update.report.items = try store.page(limit: previewLimit, processableOnly: true).items }
                catch { update.errors.append("可处理候选预览更新失败，原索引已保留：\(error.localizedDescription)") }
            } catch { update.errors.append("可处理列表更新失败，原索引已保留：\(error.localizedDescription)") }
        } else if snapshot.items.count <= previewLimit {
            update.report.items = remainingPreview(snapshot.items)
            let remaining = update.report.items.filter(\.canTrash)
            update.report.totalItemCount = remaining.count
            update.report.totalProcessableBytes = remaining.reduce(0) { $0 + $1.bytes }
            update.counts[.processable] = remaining.count
        } else { update.errors.append("候选预览超过单页大小且没有落盘索引，原列表已保留，未截断未处理内容。") }
        if let reference = snapshot.readOnlyStore {
            do {
                let statistics = try ScanResultStore(reference: reference, readOnly: false).removeProcessedPaths(paths)
                update.report.readOnlyStoredCount = statistics.totalCount
                update.counts[.readOnly] = statistics.totalCount
            } catch { update.errors.append("只读发现列表更新失败，原索引已保留：\(error.localizedDescription)") }
        }
        if let reference = snapshot.diskCoverage?.issueStore {
            do {
                let statistics = try ScanResultStore(reference: reference, readOnly: false).removeProcessedPaths(paths)
                update.report.diskCoverage?.issueCount = statistics.totalCount
                update.counts[.issues] = statistics.totalCount
            } catch { update.errors.append("访问问题列表更新失败，原索引已保留：\(error.localizedDescription)") }
        }
        return update
    }
    private func finish(_ id: UUID) {
        guard requestID == id else { return }
        phase = nil; token = nil; mailbox = nil; requestID = nil; detectionID = nil; poll?.cancel(); poll = nil; task = nil
    }
}

@MainActor
struct SmartCareView: View {
    @ObservedObject private var state: SmartCareViewState
    @ObservedObject private var tasks: DetectionTaskCenter
    @State private var showingAccessGuide = false
    @State private var coverageExpanded = false
    init(registry: FeatureStateRegistry? = nil) {
        let registry = registry ?? FeatureStateRegistry.shared
        let controller: SmartCareViewState = registry.retain("smartCare") { SmartCareViewState(taskCenter: registry.tasks) }
        _state = ObservedObject(wrappedValue: controller)
        _tasks = ObservedObject(wrappedValue: registry.tasks)
    }
    var body: some View {
        GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(eyebrow: "AIYOUClean · whole-disk review", title: "智能检查", detail: state.scanScope == .allLocalDisks ? "检查启动磁盘与本地挂载盘，区分可处理候选、只读发现和未能访问的路径。" : "完整检查所选文件夹，区分可处理候选、只读发现和未能访问的路径。")
                controls
                if let phase = state.phase {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(phase).font(.callout)
                            if let progress = state.progress { Text("已访问\(progress.visitedFiles)项 · \(progress.path)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(smartSecondary) }
                        }
                        Spacer(); Button("取消") { state.cancelCurrentTask() }
                    }
                }
                if let report = state.report {
                    candidateSummary(report)
                    if let coverage = report.diskCoverage { coveragePanel(coverage) }
                    if needsAccessHelp(report) { permissionNotice }
                    resultModePicker
                    DisclosureGroup("模块与检查提示（\(report.modules.count)个模块）") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(report.modules) { moduleCard($0) }
                                if !report.warnings.isEmpty { warningList(report.warnings, title: "检查提示") }
                                if !state.errors.isEmpty { warningList(state.errors, title: "处理错误") }
                            }
                        }.frame(maxHeight: 110)
                    }.font(.caption).foregroundStyle(smartSecondary)
                    candidateList(report)
                } else {
                    if !state.errors.isEmpty { warningList(state.errors, title: "处理错误") }
                    Spacer(minLength: 0)
                    Text("按所选范围开始检查。受保护或未授权的路径会单独记录，不会自动选择或清理任何项目。")
                        .font(.callout).foregroundStyle(smartSecondary).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let report = state.report { actionBar(report) }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .onAppear { state.resume() }
        .onChange(of: state.includeApplications) { _ in state.invalidateForOptions() }
        .onDisappear { state.stopOnDisappear() }
        .sheet(isPresented: $showingAccessGuide) { PermissionGuideView(canRescan: state.canStartScan) { state.scan() } }
        .sheet(item: $state.confirmation) { pending in
            VStack(alignment: .leading, spacing: 18) {
                Text("复查这\(pending.items.count)个具体项目").font(.title2.weight(.semibold))
                Text("合计候选大小\(Format.bytes(pending.bytes))。仅将下列路径移入系统废纸篓并写入恢复记录；身份已变、忽略项或运行中的应用会被拒绝。")
                    .font(.callout).foregroundStyle(smartSecondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) { ForEach(pending.items) { item in Text(item.path).font(.caption.monospaced()).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: 300)
                HStack {
                    Button("取消") { state.confirmation = nil }.keyboardShortcut(.cancelAction)
                    Spacer(); Button("移入系统废纸篓") { state.trash(pending) }.buttonStyle(.borderedProminent).tint(smartAccent).disabled(state.busy || tasks.isBusy)
                }
            }.padding(26).frame(width: 650)
        }
        .alert("智能检查结果", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) { Button("好") { state.message = nil } } message: { Text(state.message ?? "") }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("检查范围", selection: Binding(get: { state.scanScope }, set: { state.setScanScope($0) })) {
                    Text("全盘检查").tag(SmartCareScanScope.allLocalDisks)
                    Text("自选文件夹").tag(SmartCareScanScope.selectedFolders)
                }.pickerStyle(.segmented).frame(maxWidth: 250).disabled(state.busy)
                Toggle("应用关联候选", isOn: $state.includeApplications).toggleStyle(.checkbox).font(.caption).disabled(state.busy)
                    .help("是否追加本地应用关联候选，不改变文件的全盘或自选范围。")
                Spacer(minLength: 0)
                if state.scanScope == .selectedFolders { Button("选择文件夹…") { state.chooseRoots() }.disabled(state.busy) }
                Button(state.report == nil ? "开始检查" : "重新检查") { state.scan() }.buttonStyle(.borderedProminent).tint(smartAccent).disabled(!state.canStartScan || tasks.isBusy)
            }
            if state.scanScope == .allLocalDisks {
                Text("启动磁盘 / 及本地挂载盘。系统与其他用户受保护的内容仅作只读发现，部分路径可能无法读取。")
                    .font(.caption).foregroundStyle(smartSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.roots.isEmpty ? "请先选择一个或多个文件夹；不会回退到局部默认目录。" : "自选\(state.roots.count)个文件夹：" + state.roots.map(\.path).joined(separator: " · "))
                    .font(.caption).foregroundStyle(smartSecondary).lineLimit(1).help(state.roots.map(\.path).joined(separator: "\n"))
            }
        }.padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func needsAccessHelp(_ report: SmartCareReport) -> Bool { report.permissionRequiredModuleCount > 0 || (report.diskCoverage?.inaccessibleEntries ?? 0) > 0 }
    private func candidateSummary(_ report: SmartCareReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("可处理 \(report.totalItemCount) 项").font(.title2.weight(.semibold)).foregroundStyle(smartAccent)
                Text(Format.bytes(report.totalProcessableBytes)).font(.callout)
                Spacer()
                Text("只读发现 \(report.readOnlyStoredCount) 项").font(.caption).foregroundStyle(smartSecondary)
                if let coverage = report.diskCoverage, coverage.inaccessibleEntries > 0 { Text("不可访问 \(coverage.inaccessibleEntries) 项").font(.caption).foregroundStyle(.orange) }
            }
            Text(report.invalidated ? "结果已失效，请重新检查。" : (report.cancelled ? "已取消；已列出的候选仍可复查。" : (report.incomplete || report.diskCoverage?.incomplete == true || needsAccessHelp(report) ? "部分范围未完成读取；已列出的可处理候选仍可复查。" : "已检查可读范围；未自动选择或清理。")))
                .font(.caption).foregroundStyle(smartSecondary)
        }
    }
    private func coveragePanel(_ coverage: FullDiskCoverage) -> some View {
        DisclosureGroup(isExpanded: $coverageExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(coverage.cancelled ? "范围检查已取消，不能视为完整覆盖。" : (coverage.incomplete || coverage.inaccessibleEntries > 0 ? "存在未读取范围；不可访问目录可能包含更多未检查内容。" : "以下为本次实际检查根目录。"))
                        .foregroundStyle(coverage.incomplete || coverage.inaccessibleEntries > 0 ? .orange : smartSecondary)
                    ForEach(Array(coverage.roots.enumerated()), id: \.offset) { _, path in Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("访问条目\(coverage.visitedEntries) · 文件\(coverage.regularFiles) · 已统计逻辑大小\(Format.bytes(coverage.logicalBytes))")
                    Text("不可访问\(coverage.inaccessibleEntries) · 云占位跳过\(coverage.skippedCloudEntries) · 链接跳过\(coverage.skippedLinkEntries) · 忽略\(coverage.excludedEntries)")
                    ForEach(Array(coverage.notes.prefix(80).enumerated()), id: \.offset) { _, note in Text(note).textSelection(.enabled) }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
            }.frame(maxHeight: 110)
        } label: {
            Text("范围与覆盖 · 文件\(coverage.regularFiles) · 不可访问\(coverage.inaccessibleEntries) · 跳过\(coverage.skippedCloudEntries + coverage.skippedLinkEntries + coverage.excludedEntries)")
        }.font(.caption).foregroundStyle(smartSecondary)
    }
    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.circle").foregroundStyle(.orange)
            Text("部分路径访问受限；授权也可能无法绕过ACL或系统保护，其他可处理项目不受影响。")
                .font(.caption).foregroundStyle(smartSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("访问权限引导…") { showingAccessGuide = true }.font(.caption)
        }.padding(8).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private var resultModePicker: some View {
        Picker("结果类别", selection: Binding(get: { state.resultMode }, set: { state.setResultMode($0) })) {
            ForEach(SmartCareResultMode.allCases) { mode in Text("\(mode.title) \(state.modeCount(mode))").tag(mode) }
        }.pickerStyle(.segmented).disabled(state.phase != nil)
    }
    private func candidateList(_ report: SmartCareReport) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if state.pageLoading { ProgressView("读取\(state.resultMode.title)…").padding(20) }
                else if let error = state.pageError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(18) }
                else if state.pageItems.isEmpty {
                    Text(report.invalidated ? "旧结果已清空，请重新检查。" : "此类别未返回项目；请结合扫描范围与访问问题判断覆盖情况。")
                        .font(.callout).foregroundStyle(smartSecondary).padding(22)
                }
                ForEach(state.pageItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        if state.resultMode == .processable {
                            Toggle("选择\(item.name)", isOn: Binding(get: { state.selected.contains(item.path) }, set: { _ in state.toggle(item) }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(state.busy || tasks.isBusy || report.invalidated || !item.canTrash)
                        } else { Image(systemName: state.resultMode == .issues ? "exclamationmark.circle" : "doc.text").foregroundStyle(state.resultMode == .issues ? Color.orange : smartSecondary) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.path).font(.caption.monospaced()).lineLimit(1).help(item.path).textSelection(.enabled)
                            Text("\(item.category) · \(item.detail)").font(.caption).foregroundStyle(smartSecondary).lineLimit(2).help(item.detail).textSelection(.enabled)
                            if state.resultMode == .processable, let keeper = item.retainedPath { Text("保留原件：\(keeper)").font(.caption.monospaced()).foregroundStyle(smartSecondary).lineLimit(1).help(keeper) }
                        }
                        Spacer(minLength: 8)
                        Text(item.bytes > 0 ? Format.bytes(item.bytes) : "—").font(.caption.monospaced())
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder.badge.magnifyingglass") }.buttonStyle(.borderless).help("在Finder中显示").disabled(!item.path.hasPrefix("/"))
                    }.padding(12).background(Color.white.opacity(0.025))
                }
            }
        }.frame(minHeight: 0, maxHeight: .infinity).layoutPriority(-1)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05)))
    }
    private func actionBar(_ report: SmartCareReport) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Text("\(state.resultMode.title)共\(state.pageItemCount)项 · 每页200项 · 第\(state.page + 1)/\(state.pageCount)页").font(.caption).foregroundStyle(smartSecondary)
                Spacer()
                Button("上一页") { state.previousPage() }.disabled(state.busy || state.page == 0)
                Button("下一页") { state.nextPage() }.disabled(state.busy || state.page + 1 >= state.pageCount)
            }
            if state.resultMode == .processable {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选\(state.selected.count)项 · \(Format.bytes(state.selectedBytes))").font(.callout.weight(.medium))
                        Text("仅处理当前页选择，翻页清空。移入废纸篓后仍占用磁盘。")
                            .font(.caption).foregroundStyle(smartSecondary)
                    }
                    Spacer()
                    Button("选择本页") { state.selectPage() }.disabled(state.busy || tasks.isBusy || state.pageItems.isEmpty || report.invalidated)
                    Button("取消选择") { state.clearSelection() }.disabled(state.busy || state.selected.isEmpty)
                    Button("清理所选…") { state.requestTrash() }.buttonStyle(.borderedProminent).tint(smartAccent).disabled(state.busy || tasks.isBusy || state.selected.isEmpty || report.invalidated)
                }
            } else {
                Label(state.resultMode == .issues ? "访问问题仅供查看；不会尝试清理或修改这些路径。" : "只读发现仅供查看；系统与其他用户内容不会成为清理选择。", systemImage: "eye")
                    .font(.caption).foregroundStyle(smartSecondary)
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity).background(Color(red: 0.065, green: 0.075, blue: 0.13))
        .overlay(alignment: .top) { Divider() }
    }
    private func moduleCard(_ module: SmartCareModuleSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(module.kind == .protection ? "系统安全配置状态" : module.kind.title, systemImage: module.kind.symbol).font(.caption.weight(.semibold))
                Spacer()
                Text("候选\(module.processableCount) · 只读\(module.readOnlyCount) · 访问\(module.visitedFiles)").font(.caption)
                Text(module.skipped ? "未执行" : (module.permissionRequired ? "访问受限" : (module.incomplete ? "部分未完成" : "已检查"))).font(.caption).foregroundStyle(module.incomplete ? .orange : smartSecondary)
            }
            if !module.observations.isEmpty {
                DisclosureGroup("只读状态详情") { ForEach(Array(module.observations.enumerated()), id: \.offset) { _, text in Text(text).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            if !module.warnings.isEmpty { warningList(module.warnings, title: "模块提示") }
        }.padding(8).background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }
    private func warningList(_ values: [String], title: String) -> some View {
        DisclosureGroup("\(title)（\(values.count)条）") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) { ForEach(Array(values.prefix(100).enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 6)
            }.frame(maxHeight: 100)
        }.font(.caption).foregroundStyle(.orange)
    }
}
