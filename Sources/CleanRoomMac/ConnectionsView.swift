import SwiftUI
import AppKit
import CleanRoomCore

@MainActor
final class ConnectionsModel: ObservableObject {
    @Published var provider: ConnectedProvider = .googleDrive
    @Published var clientID = ""
    @Published var redirectURI = ""
    @Published var access: ConnectedAccess = .browse
    @Published var persistent = false
    @Published var status = "unconfigured：尚未配置公开客户端。"
    @Published var items: [ConnectedItem] = []
    @Published var selected: Set<String> = []
    @Published var nextCursor: String?
    @Published var pageNumber = 0
    @Published var scopeDescription = ""
    @Published var busy = false
    @Published var alert: String?
    @Published var confirmation: ConnectedRecyclePlan?
    @Published var search = ""
    private var containerID: String?
    private var client: ConnectedAccountClient?
    private var activeConfiguration: ConnectedConfiguration?
    private let authSession = ConnectedOAuthWebSession()
    private var task: Task<Void, Never>?
    private let preferencesKey = "AIYOUClean.connection-public-settings.v1"
    init() { restorePublicSettings() }
    var configuration: ConnectedConfiguration { .init(provider: provider, clientID: clientID, redirectURI: redirectURI, access: access, persistentConnection: persistent) }
    var selectedItems: [ConnectedItem] { items.filter { selected.contains($0.id) && $0.canRecycle } }
    var visibleItems: [ConnectedItem] { search.isEmpty ? items : items.filter { ($0.name + " " + $0.location + " " + $0.detail).localizedCaseInsensitiveContains(search) } }
    var configurationChanged: Bool { activeConfiguration != nil && activeConfiguration != configuration }
    func providerChanged() {
        guard !busy else { return }
        items = []; selected = []; nextCursor = nil; pageNumber = 0; containerID = nil; scopeDescription = ""; search = ""
        client = nil; activeConfiguration = nil; restorePublicSettings()
    }
    private func restorePublicSettings() {
        let saved = UserDefaults.standard.dictionary(forKey: preferencesKey)?[provider.rawValue] as? Data
        if let saved, let c = try? JSONDecoder().decode(ConnectedConfiguration.self, from: saved) {
            clientID = c.clientID; redirectURI = c.redirectURI; access = c.access; persistent = c.persistentConnection
            activeConfiguration = c
            status = "配置已载入；尚未读取账户。"
        } else {
            clientID = ""; redirectURI = ConnectedConfiguration.suggestedRedirect(provider: provider, clientID: ""); access = .browse; persistent = false
            status = "unconfigured：尚未配置公开客户端。"
        }
    }
    private func prepareClient() throws -> ConnectedAccountClient {
        let c = configuration
        guard c.validationIssue == nil else { throw c.clientID.isEmpty ? ConnectedError.unconfigured : ConnectedError.invalidConfiguration }
        if let client, activeConfiguration == c { return client }
        if let previous = activeConfiguration, previous != c, previous.credentialKey != c.credentialKey {
            // Replacing a public configuration discards the no-longer-used local credential.
            try ConnectedKeychainStore().remove(key: previous.credentialKey)
        }
        let newClient = try ConnectedAccountClient(configuration: c)
        client = newClient; activeConfiguration = c
        items = []; selected = []; nextCursor = nil; pageNumber = 0; containerID = nil; scopeDescription = ""
        return newClient
    }
    func saveConfiguration() {
        do {
            _ = try prepareClient()
            var saved = UserDefaults.standard.dictionary(forKey: preferencesKey) ?? [:]
            saved[provider.rawValue] = try JSONEncoder().encode(configuration)
            UserDefaults.standard.set(saved, forKey: preferencesKey)
            status = "公开配置已保存；凭证只由系统授权与钥匙串管理。"
        } catch { alert = safe(error) }
    }
    func connect() {
        do {
            let client = try prepareClient(); saveConfiguration(); busy = true; status = "等待服务商系统授权窗口…"
            task = Task { [weak self] in
                guard let self else { return }
                defer { busy = false }
                do { try await client.authorize(using: authSession); status = "已完成授权。尚未读取列表；点击读取第一页。" }
                catch { status = "授权未完成。"; alert = safe(error) }
            }
        } catch { alert = safe(error) }
    }
    func loadFirst() { load(cursor: nil, container: containerID, resetPage: true) }
    func loadRoot() { load(cursor: nil, container: nil, resetPage: true) }
    func loadNext() { guard let nextCursor else { return }; load(cursor: nextCursor, container: containerID, resetPage: false) }
    func enter(_ item: ConnectedItem) { guard item.isContainer, provider == .oneDrive else { return }; load(cursor: nil, container: item.id, resetPage: true) }
    private func load(cursor: String?, container: String?, resetPage: Bool) {
        guard !busy else { return }
        do {
            let client = try prepareClient(); busy = true; selected = []; status = "正在读取元数据；不读取正文或附件…"
            task = Task { [weak self] in
                guard let self else { return }; defer { busy = false }
                do {
                    let page = try await client.listPage(cursor: cursor, containerID: container)
                    items = page.items // Replace, never append; current-page memory is bounded to 50 items.
                    nextCursor = page.nextCursor; containerID = container; scopeDescription = page.scopeDescription
                    pageNumber = resetPage ? 1 : pageNumber + 1
                    status = "第 \(pageNumber) 页 · 当前保留 \(items.count)/50 项。换页会释放上一页。"
                } catch { alert = safe(error); status = "列表未更新；原页面仍保留供核对。" }
            }
        } catch { alert = safe(error) }
    }
    func prepareConfirmation() {
        guard !busy, !configurationChanged, !selectedItems.isEmpty, let client else { return }
        let selected = selectedItems; busy = true
        task = Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do { confirmation = try await client.prepareRecycle(selected) } catch { alert = safe(error) }
        }
    }
    func recycleConfirmed(_ plan: ConnectedRecyclePlan) {
        guard !busy, let client else { return }
        confirmation = nil; busy = true; selected = []
        task = Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do {
                let result = try await client.recycle(plan, confirmed: true)
                let completed = Set(result.recycledIDs); items.removeAll { completed.contains($0.id) }
                status = "服务商确认已回收 \(result.recycledIDs.count) 项。其他设备的同步状态需在服务商页面核对。"
                alert = "已确认回收：\(result.recycledIDs.count) 项。\n恢复请使用对应服务商的回收站/已删除项目页面，恢复期限以账户策略为准。" + (result.failures.isEmpty ? "" : "\n\n未确认完成：\n" + result.failures.joined(separator: "\n"))
            } catch { alert = safe(error) }
        }
    }
    func disconnectLocal() {
        guard !busy else { return }
        do {
            let client = try prepareClient(); busy = true
            task = Task { [weak self] in
                guard let self else { return }; defer { busy = false }
                do {
                    try await client.disconnect(); items = []; selected = []; nextCursor = nil; pageNumber = 0; containerID = nil
                    status = "本机钥匙串凭证已移除。服务商授权未被撤销，可在其账户设置中管理。"
                } catch { alert = safe(error) }
            }
        } catch { alert = safe(error) }
    }
    func cancel() { task?.cancel(); authSession.cancel() }
    private func safe(_ error: Error) -> String { (error as? ConnectedError)?.errorDescription ?? (error is CancellationError ? "已取消操作。" : "操作未完成；未输出响应正文或凭证。") }
}

struct ConnectionsView: View {
    @StateObject private var model = ConnectionsModel()
    private let accent = Color(red: 0.61, green: 0.49, blue: 1)
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("云盘与邮箱").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("按需连接，逐页查看元数据；由你明确选择待回收项目。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("服务商", selection: $model.provider) {
                    ForEach(ConnectedProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }.frame(width: 205).disabled(model.busy)
            }
            configuration
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
            }
            if !model.scopeDescription.isEmpty { Text(model.scopeDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("第 \(model.pageNumber) 页 · \(model.items.count) 项").font(.headline)
                Spacer()
                TextField("仅搜索当前页", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                if model.provider == .oneDrive { Button("根目录") { model.loadRoot() }.disabled(model.busy || model.configurationChanged) }
                Button(model.pageNumber == 0 ? "读取第一页" : "刷新当前范围") { model.loadFirst() }.disabled(model.busy || model.configurationChanged)
                Button("下一页（替换）") { model.loadNext() }.disabled(model.busy || model.nextCursor == nil || model.configurationChanged)
            }
            if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.provider.isMail ? "envelope" : "icloud").font(.system(size: 40)).foregroundStyle(accent)
                    Text(model.pageNumber == 0 ? "尚未读取账户内容" : "当前页没有返回项目").font(.headline)
                    Text("每页最多 50 项，只保留当前页。请求并发上限 2，单响应上限 2 MiB；不在后台自动轮询。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.visibleItems) { item in itemRow(item) }
                    }
                }.background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text("已选 \(model.selectedItems.count)/50 项 · 不提供永久删除").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开服务商回收站") { NSWorkspace.shared.open(model.provider.recoveryURL) }
                Button("检查并回收…") { model.prepareConfirmation() }.buttonStyle(.borderedProminent).tint(accent)
                    .disabled(model.busy || model.selectedItems.isEmpty || model.configurationChanged)
            }
            Text("iCloud：使用侧栏“云存储本地文件”扫描本机文件提供者目录；此连接页不提供 iCloud 远端 API。远端恢复由服务商处理，保留期限和组织策略可能不同。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28)
        .onChange(of: model.provider) { _ in model.providerChanged() }
        .alert("连接与操作结果", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) { Button("好") { model.alert = nil } } message: { Text(model.alert ?? "") }
        .sheet(item: $model.confirmation) { plan in confirmation(plan) }
    }
    private var configuration: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                TextField("公开 Client ID / Dropbox App Key（不是 Token）", text: $model.clientID).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("原生回调 URI / Google 本机 loopback 模板", text: $model.redirectURI).textFieldStyle(.roundedBorder)
                    Button("生成建议值") { model.redirectURI = ConnectedConfiguration.suggestedRedirect(provider: model.provider, clientID: model.clientID) }
                }
                HStack {
                    Picker("授权能力", selection: $model.access) { ForEach(ConnectedAccess.allCases, id: \.rawValue) { Text($0.title).tag($0) } }.frame(width: 260)
                    Toggle("保持连接（请求刷新凭证）", isOn: $model.persistent).toggleStyle(.checkbox)
                }
                if model.provider.serviceFamily == "google" {
                    Text("Desktop客户端建议使用http://127.0.0.1:0/oauth/…；0表示每次仅绑定本机随机端口，180秒后自动关闭。自定义scheme仍需与客户端注册匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("本次申请范围：" + model.configuration.scopes.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let issue = model.configuration.validationIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if model.configurationChanged { Text("配置已改变。请保存并重新连接后读取新范围；当前列表不能操作。").font(.caption).foregroundStyle(.orange) }
                if model.provider == .gmail && model.access == .recycle {
                    Text("Gmail 回收最低需要 gmail.modify；该服务商范围也具备读写与发信能力。本应用没有发信、退订或永久删除接口。").font(.caption).foregroundStyle(.orange)
                }
                if model.provider == .googleDrive && model.access == .recycle {
                    Text("Google Drive 全盘文件回收需要受限 drive 范围；drive.file 仅覆盖单独授权文件，不能完成全盘清理。本应用只列本人拥有的文件。").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("保存公开配置") { model.saveConfiguration() }
                    Button("通过系统窗口授权…") { model.connect() }.buttonStyle(.borderedProminent).tint(accent).disabled(model.configuration.validationIssue != nil)
                    Button("移除本机连接") { model.disconnectLocal() }
                    Spacer()
                    Text("Token 仅存系统钥匙串").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 10).disabled(model.busy)
        } label: { Label("客户端配置与连接（默认未配置）", systemImage: "key.horizontal") }
        .padding(15).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
    private func itemRow(_ item: ConnectedItem) -> some View {
        HStack(spacing: 12) {
            Toggle("选择 " + item.name, isOn: Binding(get: { model.selected.contains(item.id) }, set: { selected in
                if selected { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(!item.canRecycle || model.busy || model.configurationChanged)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(item.bytes > 0 ? Format.bytes(item.bytes) : "—").font(.caption.monospaced()).foregroundStyle(.secondary)
            if item.isContainer { Button("进入") { model.enter(item) }.disabled(model.busy || model.configurationChanged) }
        }.padding(12).background(.white.opacity(0.02))
    }
    private func confirmation(_ plan: ConnectedRecyclePlan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认回收到 \(plan.provider.title) 的已删除项目").font(.title2.weight(.semibold))
            Text("将处理以下 \(plan.items.count) 个明确项目。此操作会同步影响该账户的其他设备。恢复请到服务商回收站，期限以其账户政策为准。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text(item.location + "\nID: " + item.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 320)
            Text("本次确认仅可使用一次，5 分钟后过期。不会清空回收站、发送邮件或退订。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.confirmation = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认回收这些项目") { model.recycleConfirmed(plan) }.buttonStyle(.borderedProminent).tint(accent)
            }
        }.padding(25).frame(width: 650)
    }
}
