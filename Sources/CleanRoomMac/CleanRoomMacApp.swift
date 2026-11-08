import SwiftUI
import AppKit
import CleanRoomCore

@main
struct AIYOUCleanApp: App {
    @StateObject private var state = AppState()
    private var windowTitle: String { "AIYOUClean " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.2") }
    var body: some Scene {
        WindowGroup(windowTitle) {
            MainView().environmentObject(state).preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 730)
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置与忽略清单…") { state.destination = .preferences }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("选择扫描文件夹…") { state.chooseRoots() }.keyboardShortcut("o").disabled(state.detectionUnavailable || !state.supportsStandardScan || state.kind == .protection)
                Button("开始扫描") { state.scan() }.keyboardShortcut("r").disabled(state.detectionUnavailable || !state.supportsStandardScan)
                Button("取消检测") { state.taskCenter.cancelActive() }.keyboardShortcut(".").disabled(state.taskCenter.active?.canCancel != true || state.taskCenter.active?.isCancelling == true)
                Divider()
                Button("导出扫描报告…") { state.exportReport() }.keyboardShortcut("e").disabled(state.report == nil || state.detectionUnavailable)
            }
        }
        MenuBarExtra("AIYOUClean", systemImage: "sparkles.rectangle.stack") {
            Text("AIYOUClean").font(.headline)
            Text(state.snapshot.host)
            Divider()
            Text("磁盘可用：\(Format.bytes(state.snapshot.availableDisk))")
            Text("系统内存总量：\(state.memoryText(state.snapshot.totalMemory))")
            Text("AIYOUClean进程RSS：\(state.processResidentBytes.map { state.memoryText($0) } ?? "未读取到")")
            Text("系统负载：\(state.snapshot.loadAverage)")
            Text("电池：\(state.batterySummary)")
            Divider()
            DetectionMenuStatus(tasks: state.taskCenter) { destination in
                state.destination = destination
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Button("刷新状态") { state.refreshSystem() }
            Button("显示窗口") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            Button("退出 AIYOUClean") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor
private struct DetectionMenuStatus: View {
    @ObservedObject var tasks: DetectionTaskCenter
    let show: (Destination) -> Void
    var body: some View {
        if let activity = tasks.active {
            Text(activity.title)
            Text("已检查\(activity.count)项")
            Button("查看检测任务") { show(activity.destination) }
            if activity.canCancel { Button("取消检测") { tasks.cancelActive() }.disabled(activity.isCancelling) }
            Divider()
        }
    }
}
