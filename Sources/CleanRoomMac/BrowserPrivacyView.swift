import SwiftUI
import AppKit
import CleanRoomCore

private final class PrivacyCancellationFlag:@unchecked Sendable {
    private let lock=NSLock();private var cancelled=false
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    var value:Bool {lock.lock();defer {lock.unlock()};return cancelled}
}
private final class PrivacyPanelReference:@unchecked Sendable {
    @MainActor weak var value:BrowserPrivacyViewModel?
    @MainActor init(_ value:BrowserPrivacyViewModel) {self.value=value}
}
private enum PrivacyPanelResult:Sendable {
    case scanned(BrowserPrivacyReport)
    case cleared(BrowserPrivacyClearResult,[BrowserPrivacyBackupReceipt])
    case exported(String)
    case failure(String)
}
@MainActor
private final class BrowserPrivacyViewModel:ObservableObject {
    let taskCenter:DetectionTaskCenter
    @Published var report:BrowserPrivacyReport?
    @Published var selected=Set<String>()
    @Published var roots:[URL]=[]
    @Published var records:[BrowserPrivacyBackupReceipt]=[]
    @Published var busy=false
    @Published var busyTitle=""
    @Published var message:String?
    @Published var confirmClear=false
    private let service:BrowserPrivacyService
    private let home:URL
    private var flag:PrivacyCancellationFlag?
    private var task:Task<Void,Never>?
    private var poll:Task<Void,Never>?
    private var operationID:UUID?
    private var presentationActive=true
    var selectedItems:[BrowserPrivacyItem] {report?.items.filter {selected.contains($0.id)} ?? []}
    init(taskCenter:DetectionTaskCenter?=nil,service:BrowserPrivacyService?=nil,home:URL?=nil) {
        self.taskCenter=taskCenter ?? .shared
        self.service=service ?? BrowserPrivacyService()
        self.home=home ?? FileManager.default.homeDirectoryForCurrentUser
        records=self.service.receipts() // Bounded app-owned receipts; never an automatic browser scan.
    }
    func chooseRoots() {
        guard !busy,!taskCenter.isBusy else {return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=true
        panel.message="选择 Chrome 用户数据目录（含 Default / Profile 文件夹），或 Firefox 的 Profiles 目录。"
        if panel.runModal() == .OK,!taskCenter.isBusy {roots=panel.urls;report=nil;selected=[]}
    }
    func resetRoots() {guard !busy,!taskCenter.isBusy else {return};roots=[];report=nil;selected=[]}
    private func start(_ title:String,clearSelection:Bool=false,work:@escaping @Sendable (PrivacyCancellationFlag)->PrivacyPanelResult) {
        guard !busy else {return}
        let token=PrivacyCancellationFlag(),center=taskCenter,receiver=PrivacyPanelReference(self)
        guard let id=center.begin(title,destination:.privacy,cancel:{ [weak self] in self?.cancel();token.cancel()}) else {
            message="另一项检测或处理仍在运行，请等待完成或取消当前全局任务。";return
        }
        busy=true;busyTitle=title;flag=token;operationID=id;confirmClear=false
        if clearSelection {selected=[]}
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:200_000_000)} catch {break}
                guard let self,self.operationID==id else {break}
                // Core exposes no live record count; do not invent one while SQL/backup runs.
                center.update(id,count:0,path:self.busyTitle,phase:self.busyTitle)
            }
        }
        task=Task {
            let result=await Task.detached(priority:.utility) {work(token)}.value
            defer {center.finish(id)}
            guard let target=receiver.value,target.operationID==id else {return}
            switch result {
            case .scanned(let report):
                if report.items.isEmpty,report.warnings.contains(where:{$0.contains("另一项重任务")}) {target.message=report.warnings.joined(separator:"\n")}
                else {target.report=report}
                center.update(id,count:report.items.count,path:"已统计数据库类别",phase:title)
            case .cleared(let result,let records):
                if result.receipts.isEmpty,result.errors.contains(where:{$0.contains("另一项扫描、检测或维护")}) {
                    target.message=result.errors.joined(separator:"\n");target.records=records;break
                }
                target.message="实际删除 SQLite 记录：\(result.deletedRecords) 条；已处理 \(result.receipts.count) 个数据库。"+(result.cancelled ? "\n操作已取消；已提交的数据库不会伪称撤回。" : "")+(result.errors.isEmpty ? "" : "\n提示/未处理：\n"+result.errors.prefix(20).joined(separator:"\n"))
                target.selected=[];target.report=nil;target.records=records
                center.update(id,count:result.receipts.count,path:"已处理数据库",phase:title)
            case .exported(let text):target.message=text;center.update(id,count:1,path:"备份副本",phase:title)
            case .failure(let error):target.message=error
            }
            target.busy=false;target.flag=nil;target.task=nil;target.operationID=nil;target.poll?.cancel();target.poll=nil
        }
    }
    func scan() {
        let roots=self.roots,service=self.service,home=self.home
        start("只读统计浏览器数据库",clearSelection:true) {token in
            .scanned(service.scan(home:home,profileRoots:roots,isCancelled:{token.value}))
        }
    }
    func toggle(_ item:BrowserPrivacyItem) {guard !busy,item.records>0 else {return};if selected.contains(item.id) {selected.remove(item.id)} else {selected.insert(item.id)}}
    func clear() {
        guard !busy,!selectedItems.isEmpty else {return}
        let items=selectedItems,service=self.service
        start("备份并清理所选数据库类别",clearSelection:true) {token in
            let result=service.clear(items,confirmed:true,isCancelled:{token.value})
            return .cleared(result,service.receipts())
        }
    }
    func cancel() {
        if let id=operationID {taskCenter.markCancelling(id)}
        flag?.cancel();if busy {busyTitle="已请求取消，等待当前数据库或文件操作结束"}
    }
    func suspendPresentation() {presentationActive=false;selected=[];confirmClear=false}
    func resumePresentation() {presentationActive=true}
    func export(_ record:BrowserPrivacyBackupReceipt) {
        guard !busy,!taskCenter.isBusy else {return}
        let panel=NSSavePanel();panel.nameFieldStringValue="AIYOUClean-PrivacyBackup-"+record.id.uuidString+".sqlite"
        panel.message="导出包含原始隐私数据的备份副本。只允许新文件，不会覆盖浏览器当前数据库。"
        guard panel.runModal() == .OK,let destination=panel.url else {return}
        let service=self.service
        start("导出备份副本") {token in
            if token.value {return .failure("导出已取消，尚未开始复制。")}
            do {
                try service.exportBackup(record,to:destination,confirmed:true)
                let note=token.value ? "\n取消请求到达时复制已完成；这是已导出的新副本。" : ""
                return .exported("已导出到："+destination.path+"\n这是副本，未覆盖当前浏览器数据库。"+note)
            } catch {return .failure(error.localizedDescription)}
        }
    }
}
@MainActor
struct BrowserPrivacyView:View {
    @ObservedObject private var model:BrowserPrivacyViewModel
    @ObservedObject private var tasks:DetectionTaskCenter
    init(registry:FeatureStateRegistry?=nil) {
        let registry=registry ?? .shared
        _model=ObservedObject(wrappedValue:registry.retain("privacy") {BrowserPrivacyViewModel(taskCenter:registry.tasks)})
        _tasks=ObservedObject(wrappedValue:registry.tasks)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("浏览隐私").font(.largeTitle.bold())
            Text("Chrome / Firefox：只统计数据库记录，不显示网址、标题、下载路径或 Cookie 值。默认不选择任何项目。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("统计配置目录") {model.scan()}.disabled(model.busy || tasks.isBusy)
                Button("选择配置目录…") {model.chooseRoots()}.disabled(model.busy || tasks.isBusy)
                if !model.roots.isEmpty {Button("恢复默认目录") {model.resetRoots()}.disabled(model.busy || tasks.isBusy)}
                Spacer()
                if model.busy {ProgressView().controlSize(.small);Text(model.busyTitle).font(.caption);Button("取消") {model.cancel()}}
            }
            if !model.roots.isEmpty {Text(model.roots.map(\.path).joined(separator:"\n")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)}
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if let report=model.report {
                        if report.truncated {Text("统计不完整，请缩小范围或查看提示。").foregroundStyle(.orange)}
                        if !report.warnings.isEmpty {DisclosureGroup("统计提示（\(report.warnings.count)）") {ForEach(Array(report.warnings.enumerated()),id:\.offset) {_,warning in Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}}}
                        if report.items.isEmpty {Text("未返回兼容数据库；可能未安装、路径或权限不匹配。此结果不代表没有隐私数据。").foregroundStyle(.secondary)}
                        LazyVStack(spacing:8) {ForEach(report.items) {item in privacyRow(item)}}
                    } else {Text("点击统计后才会读取 Schema 与 COUNT。最多30个配置目录、100个结果，SQLite逐个打开、缓存有界；不扫描Safari或钥匙串。").font(.callout).foregroundStyle(.secondary)}
                    if !model.selectedItems.isEmpty {
                        HStack {Text("已选 \(model.selectedItems.count) 类 · \(model.selectedItems.reduce(Int64(0)) {$0+$1.records}) 条SQLite记录");Spacer();Button("检查并备份清理…") {model.confirmClear=true}.buttonStyle(.borderedProminent).disabled(model.busy || tasks.isBusy)}
                    }
                    Divider().padding(.vertical,8)
                    Text("本地备份收据（最多100项）").font(.headline)
                    if model.records.isEmpty {Text("还没有本应用创建的隐私数据库备份。").font(.callout).foregroundStyle(.secondary)}
                    LazyVStack(spacing:8) {ForEach(model.records) {record in backupRow(record)}}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("清理前必须完全退出对应浏览器及后台进程。Cookies 清理可能退出网站登录。每个数据库先在线分页备份，再事务删除；失败回滚。不删除WAL文件、不自动VACUUM。Firefox访问事件清理保留URL/书签结构，不等于抹除所有痕迹；同步也可能重新带回记录。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).onAppear {model.resumePresentation()}.onDisappear {model.suspendPresentation()}
        .alert("浏览隐私",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) {Button("好") {model.message=nil}} message: {Text(model.message ?? "")}
        .sheet(isPresented:$model.confirmClear) {confirmation}
    }
    private func privacyRow(_ item:BrowserPrivacyItem) -> some View {
        HStack(alignment:.top,spacing:12) {
            Toggle("选择",isOn:Binding(get:{model.selected.contains(item.id)},set:{_ in model.toggle(item)})).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || item.records==0)
            VStack(alignment:.leading,spacing:4) {
                Text(item.category.browser.title+" / "+item.profile+" / "+item.category.title).font(.headline)
                Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(item.tableCounts.keys.sorted().map {$0+": "+String(item.tableCounts[$0] ?? 0)}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer();Text("\(item.records) 条").font(.callout.monospacedDigit())
        }.padding(12).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
    }
    private func backupRow(_ record:BrowserPrivacyBackupReceipt) -> some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading,spacing:5) {
                Text(record.browser.title+" · "+record.date.formatted(date:.numeric,time:.shortened)).font(.callout.bold())
                Text(record.originalPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(record.state == .cleared ? "已清理并保留备份 · 实际删除 \(record.deletedRecords.values.reduce(0,+)) 条" : "已备份；未确认清理提交状态，可重新统计核对").font(.caption).foregroundStyle(.secondary)
            }
            Spacer();Button("导出备份副本…") {model.export(record)}.disabled(model.busy || tasks.isBusy)
        }.padding(12).background(Color.white.opacity(0.03),in:RoundedRectangle(cornerRadius:10))
    }
    private var confirmation:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("确认所选隐私数据库类别").font(.title2.bold())
            Text("先备份，再删除以下类别的数据库记录。不会删除下载文件，不会覆盖当前数据库进行恢复；备份只能导出新副本。Cookie 清理可能退出网站登录。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {VStack(alignment:.leading,spacing:12) {ForEach(model.selectedItems) {item in
                VStack(alignment:.leading,spacing:4) {Text(item.category.browser.title+" / "+item.profile+" / "+item.category.title).font(.callout.bold());Text(item.path).font(.caption.monospaced()).textSelection(.enabled);Text("统计 \(item.records) 条数据库记录").font(.caption)};Divider()
            }}}.frame(maxHeight:320)
            Text("相应浏览器或后台进程仍在运行、数据库已变化、Schema不兼容、备份/事务失败时不会提交该数据库。多个数据库分别处理，取消不撤回此前已成功提交的数据库。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {Button("取消") {model.confirmClear=false};Spacer();Button("备份并清理所选类别") {model.clear()}.buttonStyle(.borderedProminent).disabled(model.busy || tasks.isBusy)}
        }.padding(26).frame(width:700)
    }
}
