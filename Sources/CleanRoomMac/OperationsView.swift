import SwiftUI
import AppKit
import CleanRoomCore

@MainActor private final class OperationsState: ObservableObject {
    let taskCenter: DetectionTaskCenter
    @Published private(set) var busy = false
    @Published private(set) var busyTitle = ""
    @Published var result = ""
    @Published var pending: MaintenanceTaskKind?
    @Published var message: String?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    init(taskCenter: DetectionTaskCenter? = nil) { self.taskCenter = taskCenter ?? .shared }
    func request(_ kind: MaintenanceTaskKind) {
        guard !busy, !taskCenter.isBusy else { message = "另一项检测或处理仍在运行，请等待其完成后再执行维护。"; return }
        pending = kind
    }
    func perform(_ kind: MaintenanceTaskKind) {
        start(kind.title) {
            let value = MaintenanceService.execute(kind, confirmed: true)
            return (value.success ? "命令已成功返回。" : "未完成（退出码 \(value.exitCode)）。") + "\n" + value.note + "\n" + value.output
        }
    }
    func status(_ snapshots: Bool) {
        start(snapshots ? "读取本地快照" : "读取索引状态") {
            let value = snapshots ? MaintenanceService.snapshots() : MaintenanceService.spotlightStatus()
            return "退出码 \(value.code)\n" + value.output
        }
    }
    private func start(_ title: String, work: @escaping @Sendable () -> String) {
        guard !busy else { return }
        let center = taskCenter
        // These fixed maintenance APIs do not expose worker cancellation. The
        // ticket remains occupied until the command returns or its own timeout.
        guard let id = center.begin(title, destination: .maintenance, cancel: nil) else {
            message = "另一项检测或处理仍在运行，请等待其完成后再执行维护。"; return
        }
        pending = nil; message = nil; busy = true; busyTitle = title; operationID = id
        center.update(id, count: 0, path: "", phase: "正在执行并等待系统响应")
        task = Task { [weak self] in
            let value = await Task.detached(priority: .utility) { work() }.value
            defer { center.finish(id) }
            guard let self, self.operationID == id else { return }
            self.result = value
            center.update(id, count: 1, path: "", phase: "系统命令已返回")
            self.busy = false; self.busyTitle = ""; self.operationID = nil; self.task = nil
        }
    }
    func stopPresentation() { pending = nil }
}
struct OperationsView: View {
    @ObservedObject private var model: OperationsState
    @ObservedObject private var tasks: DetectionTaskCenter
    init(registry: FeatureStateRegistry? = nil) {
        let registry = registry ?? .shared
        _model = ObservedObject(wrappedValue: registry.retain("operations") { OperationsState(taskCenter: registry.tasks) })
        _tasks = ObservedObject(wrappedValue: registry.tasks)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("系统维护").font(.largeTitle.bold())
            Text("每项操作都有固定命令与实际回读；管理员任务由 macOS 弹出授权窗口。任务未执行前不会修改系统。")
                .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(MaintenanceTaskKind.allCases.filter { $0 != .freeMemory && MaintenanceService.plan($0).supported }) { kind in
                            let plan = MaintenanceService.plan(kind)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(kind.title).font(.headline); Spacer(); Button("检查并执行…") { model.request(kind) }.disabled(model.busy || tasks.isBusy || !plan.supported) }
                                Text(kind.detail).font(.callout).foregroundStyle(.secondary)
                                Text(plan.preview).font(.caption.monospaced()).textSelection(.enabled)
                            }.padding().background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                HStack { Button("查看本地快照") { model.status(true) }; Button("查看索引状态") { model.status(false) } }.disabled(model.busy || tasks.isBusy)
            if model.busy {
                ProgressView(model.busyTitle + " · 等待系统响应…").controlSize(.small)
                Text("此命令不支持中断；切换页面后继续执行，系统返回后可在这里查看结果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.result.isEmpty {
                ScrollView { Text(model.result).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180).padding().background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(24)
        .sheet(item: $model.pending) { kind in
            VStack(alignment: .leading, spacing: 16) {
                Text(kind.title).font(.title2.bold()); Text(kind.detail)
                Text(MaintenanceService.plan(kind).preview).font(.caption.monospaced()).textSelection(.enabled)
                if kind == .thinSnapshots { Text("本地快照缩减后可能无法恢复其中的历史状态。请确认当前确实需要执行。").foregroundStyle(.orange) }
                HStack { Button("取消") { model.pending = nil }; Spacer(); Button("执行以上任务") { model.perform(kind) }.buttonStyle(.borderedProminent).disabled(model.busy || tasks.isBusy) }
            }.padding(24).frame(width: 640)
        }
        .onDisappear { model.stopPresentation() }
        .alert("系统维护", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
