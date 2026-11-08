import SwiftUI
import AppKit
import CleanRoomCore

private let preferencesAccent = Color(red: 0.61, green: 0.49, blue: 1)
private let preferencesSecondary = Color(red: 0.65, green: 0.68, blue: 0.78)
private enum IgnorePreferenceResult: Sendable { case loaded([String]), saved([String]), failure(String) }
@MainActor
private final class IgnorePreferencesState: ObservableObject {
    @Published private(set) var paths: [String] = []
    @Published private(set) var savedPaths: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var loadedWithError = false
    @Published var draftPath = ""
    @Published var selected: Set<String> = []
    @Published var message: String?
    @Published var error: String?
    private var loaded = false
    private var task: Task<Void, Never>?
    var hasChanges: Bool { paths != savedPaths || loadedWithError }
    func loadIfNeeded() { if !loaded { loaded = true; load() } }
    func load() {
        guard !busy else { return }; busy = true; error = nil
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> IgnorePreferenceResult in
                do { return .loaded(try IgnoreRuleStore().load()) } catch { return .failure(error.localizedDescription) }
            }.value
            guard let self else { return }; self.apply(result)
        }
    }
    func addPaths(_ new: [String]) {
        guard !busy else { return }
        do { paths = try IgnoreRuleStore.normalize(Array(Set(paths + new))); draftPath = "" }
        catch { message = error.localizedDescription }
    }
    func choosePaths() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选中的绝对路径及其子项将加入忽略草稿，保存后下次扫描生效。"
        if panel.runModal() == .OK { addPaths(panel.urls.map(\.path)) }
    }
    func removeSelected() { guard !busy else { return }; paths.removeAll { selected.contains($0) }; selected = [] }
    func save() {
        guard !busy else { return }; busy = true; error = nil
        let values = paths
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> IgnorePreferenceResult in
                do { let store = IgnoreRuleStore(); try store.save(values); return .saved(try store.load()) }
                catch { return .failure(error.localizedDescription) }
            }.value
            guard let self else { return }; self.apply(result)
        }
    }
    private func apply(_ result: IgnorePreferenceResult) {
        busy = false; task = nil
        switch result {
        case .loaded(let values): paths = values; savedPaths = values; selected = []; loadedWithError = false; error = nil
        case .saved(let values): paths = values; savedPaths = values; selected = []; loadedWithError = false; error = nil; message = "已保存\(values.count)项忽略规则。旧扫描结果已失效，下次扫描使用新清单。"
        case .failure(let reason): loadedWithError = true; error = reason
        }
    }
}

@MainActor
struct PreferencesView: View {
    @StateObject private var state = IgnorePreferencesState()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "AIYOUClean · your scan boundaries", title: "扫描设置", detail: "管理忽略清单。规则只使用规范化绝对路径，忽略该路径及全部子项；保存后下次扫描生效。")
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("适用范围").font(.headline)
                        Text("适用于普通文件扫描、智能检查、空间统计及高级候选。忽略项目不进入结果；包含忽略子项的父目录也不能整体移入废纸篓。")
                            .font(.callout).foregroundStyle(preferencesSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("不适用于浏览器隐私数据、废纸篓永久删除、文稿历史版本或ClamAV独立检测；这些独立工具由各自的明确范围和确认控制。")
                            .font(.caption).foregroundStyle(preferencesSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("不支持通配符、~展开或相对路径。最多500项、256KB。保存会使旧扫描报告失效，需重新检查。")
                            .font(.caption).foregroundStyle(preferencesSecondary)
                    }
                }
                if let error = state.error {
                    Surface {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("忽略清单未能读取或保存", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                            Text(error).font(.callout).textSelection(.enabled)
                            Text("配置损坏时扫描会明确停止，不会静默忽略这些规则。你可以重新读取；保存当前明确列表将替换无法读取的旧配置。")
                                .font(.caption).foregroundStyle(preferencesSecondary)
                        }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("忽略路径（\(state.paths.count)/500）").font(.headline)
                            Spacer(); Button("选择文件或文件夹…") { state.choosePaths() }.disabled(state.busy)
                            Button("移除所选") { state.removeSelected() }.disabled(state.busy || state.selected.isEmpty)
                        }
                        HStack {
                            TextField("输入绝对路径，例如 /Users/你的账户/Documents/保留资料", text: $state.draftPath).textFieldStyle(.roundedBorder).disabled(state.busy)
                            Button("加入草稿") { state.addPaths([state.draftPath]) }.disabled(state.busy || state.draftPath.isEmpty)
                        }
                        if state.paths.isEmpty { Text("当前草稿没有忽略项。保存前不会改变已生效规则。").font(.callout).foregroundStyle(preferencesSecondary) }
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(state.paths, id: \.self) { path in
                                HStack(alignment: .top, spacing: 12) {
                                    Toggle("选择", isOn: Binding(get: { state.selected.contains(path) }, set: { chosen in if chosen { state.selected.insert(path) } else { state.selected.remove(path) } })).labelsHidden().disabled(state.busy)
                                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                                    Spacer()
                                }.padding(9).background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                HStack {
                    Button("重新读取") { state.load() }.disabled(state.busy)
                    if state.busy { ProgressView().controlSize(.small) }
                    Spacer(); Text(state.hasChanges ? "有尚未保存的更改" : "当前列表已保存").font(.caption).foregroundStyle(preferencesSecondary)
                    Button(state.loadedWithError ? "保存并修复当前清单" : "保存忽略清单") { state.save() }.buttonStyle(.borderedProminent).tint(preferencesAccent).disabled(state.busy || !state.hasChanges)
                }
            }.padding(30)
        }
        .task { state.loadIfNeeded() }
        .alert("扫描设置", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) { Button("好") { state.message = nil } } message: { Text(state.message ?? "") }
    }
}
