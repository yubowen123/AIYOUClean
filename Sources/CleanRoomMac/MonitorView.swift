import SwiftUI
import CleanRoomCore

@MainActor private final class MonitorState: ObservableObject {
    @Published var metric: LiveMetrics?
    @Published var processes: [RunningProcessInfo] = []
    @Published var samples: [Double] = []
    @Published var busy = false
    @Published var pending: RunningProcessInfo?
    @Published var message: String?
    private let sampler = MetricsSampler()
    private var task: Task<Void, Never>?
    private var running = false
    func start() {
        guard !running else { return }; running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, running else { break }
                let sampler = self.sampler
                let value = await Task.detached(priority: .utility) { sampler.sample() }.value
                if Task.isCancelled || !running { break }
                metric = value
                if let cpu = value.cpuPercent { samples.append(cpu); if samples.count > 60 { samples.removeFirst(samples.count - 60) } }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func stop() { running = false; task?.cancel(); task = nil }
    func loadProcesses() {
        guard !busy else { return }; busy = true
        Task { let list = await Task.detached(priority: .utility) { Array(ProcessMonitor.list().prefix(100)) }.value; processes = list; busy = false }
    }
    func quit(_ process: RunningProcessInfo) {
        pending = nil
        message = ProcessMonitor.terminateApp(pid: process.id, confirmed: true) ? "已向应用发送正常退出请求；如有未保存内容，应用可能提示保存。" : "应用未接受退出请求，或该项目不是可正常退出的应用。"
    }
}
struct MonitorView: View {
    @StateObject private var state = MonitorState()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("实时资源监测").font(.largeTitle.bold())
                Text("仅在此页可见时每 5 秒采样；保留最近 60 个 CPU 点。关闭页面后停止，不启动常驻后台服务。").foregroundStyle(.secondary)
                if let m = state.metric {
                    HStack(spacing: 16) {
                        tile("CPU 使用率", m.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "等待第二次采样")
                        tile("活动 / 联结 / 压缩内存", Format.bytes(Int64(m.memoryUsed)))
                        tile("内存压力", m.memoryPressure)
                    }
                    HStack(spacing: 16) { tile("接收 / 秒", m.networkReceivedPerSecond.map { Format.bytes(Int64($0)) } ?? "采样中"); tile("发送 / 秒", m.networkSentPerSecond.map { Format.bytes(Int64($0)) } ?? "采样中"); tile("本应用进程驻留内存", ProcessResources.residentBytes().map { Format.bytes(Int64($0)) } ?? "未知") }
                    Text("网络值为非回环接口合计，VPN/桥接可能重复计数。\n交换区：" + m.swapUsage).font(.caption).foregroundStyle(.secondary)
                    if !m.notices.isEmpty { Text(m.notices.joined(separator: "\n")).foregroundStyle(.orange) }
                } else { ProgressView("读取资源状态…") }
                HStack(alignment: .bottom, spacing: 3) { ForEach(Array(state.samples.enumerated()), id: \.offset) { _, value in RoundedRectangle(cornerRadius: 2).fill(Color.purple.opacity(0.8)).frame(width: 6, height: max(2, CGFloat(value))) }; Spacer() }.frame(height: 100).padding().background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                HStack { Text("进程使用量（最多显示 CPU 排名前100项）").font(.headline); Spacer(); Button("手动刷新进程") { state.loadProcesses() }.disabled(state.busy) }
                Text("只读取进程名，不读取命令行参数；退出操作仅向应用发送正常退出请求。").font(.caption).foregroundStyle(.secondary)
                LazyVStack(spacing: 8) {
                    ForEach(state.processes) { process in
                        HStack { VStack(alignment: .leading) { Text(process.name).font(.callout).lineLimit(1); Text("PID \(process.id)").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text(String(format: "%.1f%%", process.cpu)); Text(Format.bytes(process.memoryKB * 1024)).frame(width: 100, alignment: .trailing); Button("请求退出…") { state.pending = process } }.padding(10).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(24)
        }.onAppear { state.start() }.onDisappear { state.stop() }
        .sheet(item: $state.pending) { process in
            VStack(alignment: .leading, spacing: 16) { Text("请求应用正常退出").font(.title2.bold()); Text(process.name); Text("PID \(process.id)。如有未保存内容，请先核对。不会强制杀死进程。"); HStack { Button("取消") { state.pending = nil }; Spacer(); Button("发送退出请求") { state.quit(process) }.buttonStyle(.borderedProminent) } }.padding(24).frame(width: 580)
        }
        .alert("AIYOUClean", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) { Button("好") { state.message = nil } } message: { Text(state.message ?? "") }
    }
    private func tile(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14)) }
}
