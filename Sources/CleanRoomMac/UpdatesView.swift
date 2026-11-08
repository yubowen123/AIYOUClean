import SwiftUI
import AppKit
import CleanRoomCore

@MainActor
final class UpdatesViewModel:ObservableObject {
    @Published var targets:[AppUpdateTarget]=[]
    @Published var checks:[String:AppUpdateCheck]=[:]
    @Published var downloads:[String:DownloadedAppUpdate]=[:]
    @Published var prepared:[String:PreparedAppUpdate]=[:]
    @Published var query=""
    @Published var busy=false
    @Published var busyTitle=""
    @Published var cancellable=false
    @Published var message:String?
    @Published var installCandidate:String?
    @Published var systemUpdates:String?
    let service=AppUpdateService()
    private var task:Task<Void,Never>?
    var visible:[AppUpdateTarget] { targets.filter { query.isEmpty || ($0.name+" "+$0.bundleID).localizedCaseInsensitiveContains(query) } }
    func load() {
        guard !busy else { return }; begin("读取应用信息",cancellable:false)
        let service=self.service
        task=Task { let list=await Task.detached(priority:.utility) { service.inventory() }.value
            targets=list; checks=[:]; downloads=[:]; prepared=[:]; end()
        }
    }
    func check(_ target:AppUpdateTarget) {
        guard !busy else { return }; begin("检查 "+target.name,cancellable:true)
        let service=self.service
        task=Task { let result=await service.check(target); checks[target.id]=result; end() }
    }
    func checkAll() {
        guard !busy else { return }; begin("检查声明了更新源的应用（最多同时2个）",cancellable:true)
        let candidates=targets.filter { $0.distribution == .sparkle }; let service=self.service
        task=Task { let results=await service.checkAll(candidates)
            for result in results { checks[result.id]=result }; end()
        }
    }
    func download(_ check:AppUpdateCheck) {
        guard !busy else { return }; begin("下载 "+check.target.name,cancellable:true)
        let service=self.service
        task=Task {
            do { let value=try await service.download(check); downloads[check.id]=value
                message=value.signatureVerified ? "下载完成并通过原应用公钥的 Ed25519 验证。尚未提取或安装。" : "下载完成，但原应用缺少可用 Ed25519 公钥/签名。本工具不会提取或安装，请使用原应用的更新器。"
            } catch { message=error is CancellationError ? "下载已取消" : error.localizedDescription }; end()
        }
    }
    func prepare(_ item:DownloadedAppUpdate) {
        guard !busy else { return }; begin("核验并准备 "+item.check.target.name,cancellable:false)
        let service=self.service
        task=Task {
            do { let value=try await Task.detached(priority:.utility) { try service.prepare(item) }.value
                prepared[item.check.id]=value; message="包签名、应用身份、构建号、原生架构与开发者已核验。尚未替换原应用。"
            } catch { message=error.localizedDescription }; end()
        }
    }
    func install(_ item:PreparedAppUpdate) {
        guard !busy else { return }; installCandidate=nil; begin("安装 "+item.downloaded.check.target.name,cancellable:false)
        let service=self.service
        task=Task {
            do { let receipt=try await Task.detached(priority:.utility) { try service.install(item,confirmed:true) }.value
                checks.removeValue(forKey:item.downloaded.check.id); downloads.removeValue(forKey:item.downloaded.check.id); prepared.removeValue(forKey:item.downloaded.check.id)
                message="已安装并回读验证："+receipt.installedBuild+"\n旧版保留在："+receipt.backupPath
            } catch { message=error.localizedDescription }; end()
        }
    }
    func checkSystem() {
        guard !busy else { return }; begin("查询系统更新（不安装）",cancellable:false)
        let service=self.service
        task=Task { let result=await Task.detached(priority:.utility) { service.checkSystemUpdates() }.value
            systemUpdates=(result.code==0 ? "" : "查询未成功（退出码 \(result.code)）\n")+result.output; end()
        }
    }
    func cancel() { if cancellable { task?.cancel() } }
    func cancelOnDisappear() { task?.cancel() }
    func reveal(_ url:URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openStore() { if let u=URL(string:"macappstore://showUpdatesPage") { NSWorkspace.shared.open(u) } }
    func openOriginal(_ target:AppUpdateTarget) { NSWorkspace.shared.open(URL(fileURLWithPath:target.path)) }
    func openWebsite(_ release:AppcastRelease) {
        guard let u=release.websiteURL,(try? AppUpdateURLPolicy.validate(u)) != nil else { return }; NSWorkspace.shared.open(u)
    }
    private func begin(_ title:String,cancellable:Bool) { busy=true; busyTitle=title; self.cancellable=cancellable }
    private func end() { busy=false; cancellable=false; task=nil }
}

struct UpdatesView:View {
    @StateObject private var model=UpdatesViewModel()
    private let accent=Color(red:0.61,green:0.49,blue:1)
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("应用更新").font(.largeTitle.bold())
            Text("读取应用声明的更新源，先检查、再下载、核验后由你确认安装。没有更新源不代表已是最新版。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("读取应用目录") { model.load() }
                Button("检查可用更新源") { model.checkAll() }.disabled(model.targets.isEmpty)
                Button("App Store 更新") { model.openStore() }
                Button("查询 macOS 更新") { model.checkSystem() }
                Spacer()
                TextField("搜索名称或 bundle ID",text:$model.query).textFieldStyle(.roundedBorder).frame(maxWidth:230)
            }.disabled(model.busy)
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.busyTitle); Spacer(); if model.cancellable { Button("取消") { model.cancel() } } } }
            Text("仅检查用户点击的更新源；默认正式频道。源文件≤4MB，更新包≤256MB，最多2个网络检查并发。更大或特殊安装包请使用原应用更新器。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing:10) { ForEach(model.visible) { app in row(app) } }
            }
            if let system=model.systemUpdates {
                DisclosureGroup("macOS 更新查询结果（未执行安装）") {
                    ScrollView { Text(system).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:170)
                }
            }
            Text("安装仅接受原应用公钥签名的完整包、相同 bundle ID/开发者、较新构建及当前原生架构；正在运行、无写权限或 Gatekeeper 不接受时停止。旧版保留可恢复备份，不提权、不移除系统隔离。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).onAppear { if model.targets.isEmpty { model.load() } }
        .onDisappear { model.cancelOnDisappear() }
        .alert("应用更新",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) { Button("好") { model.message=nil } } message: { Text(model.message ?? "") }
        .sheet(isPresented:Binding(get:{model.installCandidate != nil},set:{if !$0 {model.installCandidate=nil}})) {
            if let id=model.installCandidate,let item=model.prepared[id] { installSheet(item) }
        }
    }
    private func row(_ app:AppUpdateTarget) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:3) { Text(app.name).font(.headline); Text(app.bundleID+" · "+app.version+" ("+app.build+")").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(model.checks[app.id]?.state.title ?? (app.distribution == .appStore ? "App Store 管理 · 未查询" : "未检查")).font(.caption).foregroundStyle(accent)
                Button("检查") { model.check(app) }.disabled(model.busy)
            }
            Text(app.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).help(app.path)
            if let result=model.checks[app.id] {
                Text(result.message).font(.caption).foregroundStyle(.secondary)
                if let release=result.release {
                    HStack {
                        Text("发布："+release.displayVersion+" · build "+release.version).font(.callout)
                        Spacer()
                        if let downloaded=model.downloads[app.id] {
                            Button("显示下载文件") { model.reveal(downloaded.archiveURL) }
                            if let prepared=model.prepared[app.id] { Button("检查并安装…") { model.installCandidate=prepared.downloaded.check.id }.disabled(model.busy) }
                            else if downloaded.signatureVerified { Button("核验应用包") { model.prepare(downloaded) }.disabled(model.busy) }
                        } else if release.archiveURL != nil && !release.isInformational { Button("下载完整包") { model.download(result) }.disabled(model.busy) }
                        if release.websiteURL != nil { Button("发布网站") { model.openWebsite(release) } }
                    }
                }
                if result.state == .appStore { Button("打开 App Store 更新页") { model.openStore() } }
                else if result.state == .noSource || result.state == .failed { Button("打开原应用") { model.openOriginal(app) } }
            }
        }.padding(15).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
    }
    private func installSheet(_ item:PreparedAppUpdate) -> some View {
        VStack(alignment:.leading,spacing:18) {
            Text("确认替换应用").font(.title2.bold())
            Text(item.downloaded.check.target.name+"："+item.downloaded.check.target.build+" → "+item.candidateBuild)
            Text(item.downloaded.check.target.path).font(.callout.monospaced()).textSelection(.enabled)
            Text("开发者："+item.originalTeamID).font(.callout)
            Text("操作将替换这一个应用，保留同目录旧版备份。运行中、签名/文件变化、系统信任或写入权限检查失败时停止。不会启动新应用。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack { Button("取消") { model.installCandidate=nil }; Spacer(); Button("安装已验证的更新") { model.install(item) }.buttonStyle(.borderedProminent).disabled(model.busy) }
        }.padding(26).frame(width:620)
    }
}
