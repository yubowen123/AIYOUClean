import SwiftUI
import AppKit
import Combine
import CleanRoomCore

private final class LensCancellationFlag:@unchecked Sendable {
    private let lock=NSLock();private var cancelled=false
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    var value:Bool {lock.lock();defer {lock.unlock()};return cancelled}
}
private final class LensProgressMailbox:@unchecked Sendable {
    private let lock=NSLock();private var pending:(Int,String)?;private var closed=false
    func offer(_ count:Int,_ path:String) {lock.lock();defer {lock.unlock()};if !closed {pending=(count,String(path.prefix(4096)))}}
    func take() -> (Int,String)? {lock.lock();defer {lock.unlock()};let value=pending;pending=nil;return value}
    func close() {lock.lock();closed=true;pending=nil;lock.unlock()}
}
private final class LensModelReference:@unchecked Sendable {
    @MainActor weak var value:SpaceLensViewModel?
    @MainActor init(_ value:SpaceLensViewModel) {self.value=value}
}
private struct LensBreadcrumb:Identifiable {let title:String;let url:URL;var id:String {url.path}}
private struct LensPageResult:Sendable {
    let page:SpaceLensPage
    let map:SpaceLensMapData?
}
@MainActor
private final class SpaceLensViewModel:ObservableObject {
    @Published var report:SpaceLensReport?
    @Published var ordered:[SpaceLensItem]=[] // Only the current 200-row page.
    @Published var tiles:[SpaceLensTile]=[]
    @Published var metric:SpaceLensMetric = .allocated
    @Published var baseRoot:URL?
    @Published var currentRoot:URL?
    @Published var busy=false
    @Published var pageLoading=false
    @Published var totalCount=0
    @Published var visited=0
    @Published var progressPath=""
    @Published var page=0
    @Published var message:String?
    @Published var logical:Int64=0
    @Published var allocated:Int64=0
    private let taskCenter:DetectionTaskCenter
    private var detectionID:UUID?
    private var ignoreRuleChanges:AnyCancellable?
    private var policyGeneration=0
    private var presentationActive=true
    private let queue=DispatchQueue(label:"local.aiyou.AIYOUClean.space-pages",qos:.utility)
    private var token:LensCancellationFlag?
    private var task:Task<Void,Never>?
    private var requestID:UUID?
    private var mailbox:LensProgressMailbox?
    private var pump:Task<Void,Never>?
    private var pageID=UUID()
    private var pageToken:LensCancellationFlag?
    private var pageTask:Task<Void,Never>?
    init(taskCenter:DetectionTaskCenter?=nil) {
        self.taskCenter=taskCenter ?? .shared
        let receiver=LensModelReference(self)
        ignoreRuleChanges=NotificationCenter.default.publisher(for:IgnoreRuleStore.didChangeNotification).sink {note in
            guard note.object as? String == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else {return}
            if Thread.isMainThread {
                MainActor.assumeIsolated {receiver.value?.rulesChanged()}
            } else {
                DispatchQueue.main.async {receiver.value?.rulesChanged()}
            }
        }
    }
    var pageCount:Int {max(1,(totalCount+199)/200)}
    var visibleItems:[SpaceLensItem] {ordered}
    var isAtBase:Bool {currentRoot==nil || currentRoot?.path==baseRoot?.path}
    var breadcrumbs:[LensBreadcrumb] {
        guard let base=baseRoot,let current=currentRoot,FileSafety.contains(base.path,current.path) else {return []}
        var output=[LensBreadcrumb(title:base.lastPathComponent.isEmpty ? base.path : base.lastPathComponent,url:base)]
        var path=base
        for component in current.pathComponents.dropFirst(base.pathComponents.count) {path.appendPathComponent(component);output.append(.init(title:component,url:path))}
        return output
    }
    func chooseRoot() {
        guard !busy else {return}
        guard !taskCenter.isBusy else {message="已有检测正在进行；请从任务栏返回查看或取消后再分析。";return}
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        panel.message="选择空间分析根目录；只读取已在本地的内容。"
        if panel.runModal() == .OK,let root=panel.url {start(root,replaceBase:true)}
    }
    private func cancelPage() {
        pageToken?.cancel();pageToken=nil;pageTask?.cancel();pageTask=nil;pageID=UUID();pageLoading=false
    }
    private func clearReport() {
        let old=report?.resultStore
        cancelPage()
        report=nil;ordered=[];tiles=[];logical=0;allocated=0;page=0;totalCount=0;pageLoading=false
        if let old {queue.async {try? SpaceLensResultStore.remove(old)}}
    }
    func start(_ root:URL,replaceBase:Bool=false) {
        guard !busy else {return}
        guard let ticket=taskCenter.begin("空间分析",destination:.scan(.spaceLens),cancel:{[weak self] in self?.cancel()}) else {
            message="已有检测正在进行；请从任务栏返回查看或取消后再分析。";return
        }
        detectionID=ticket
        if replaceBase || baseRoot==nil {baseRoot=root.standardizedFileURL}
        clearReport();currentRoot=root.standardizedFileURL;busy=true;visited=0;progressPath="正在准备持续分析…"
        let flag=LensCancellationFlag();token=flag
        let id=UUID();requestID=id;let receiver=LensModelReference(self),workQueue=queue
        let generation=policyGeneration,center=taskCenter
        let box=LensProgressMailbox();mailbox=box
        pump=Task {
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:200_000_000)} catch {return}
                guard !Task.isCancelled,let model=receiver.value,model.requestID==id else {return}
                if let update=box.take() {
                    if model.presentationActive {model.visited=update.0;model.progressPath=update.1}
                    center.update(ticket,count:update.0,path:update.1)
                }
            }
        }
        task=Task {
            let result=await Task.detached(priority:.utility) {
                SpaceLensService().scan(root:root,limits:.init(scanToCompletion:true),isCancelled:{flag.value},progress:{count,path in box.offer(count,path)})
            }.value
            box.close()
            defer {center.finish(ticket)}
            guard let model=receiver.value,model.requestID==id else {
                if let reference=result.resultStore {workQueue.async {try? SpaceLensResultStore.remove(reference)}}
                return
            }
            model.stopPump();model.visited=result.visitedEntries
            center.update(ticket,count:result.visitedEntries,path:flag.value ? "空间分析已取消" : "空间分析结果已保存")
            model.busy=false;model.token=nil;model.task=nil;model.requestID=nil;model.detectionID=nil
            guard model.policyGeneration==generation else {
                if let reference=result.resultStore {workQueue.async {try? SpaceLensResultStore.remove(reference)}}
                return
            }
            var metadata=result;metadata.items=[]
            model.report=metadata;model.logical=result.logicalBytes;model.allocated=result.allocatedBytes;model.totalCount=result.totalItemCount
            model.page=0
            if model.presentationActive {model.loadPage(reloadMap:true)}
        }
    }
    func refresh() {if let root=currentRoot {start(root)}}
    func up() {guard let root=currentRoot,!isAtBase else {return};start(root.deletingLastPathComponent())}
    func rebuild() {page=0;loadPage(reloadMap:true)}
    func previousPage() {guard !busy,!pageLoading,page>0 else {return};page-=1;loadPage()}
    func nextPage() {guard !busy,!pageLoading,page+1<pageCount else {return};page+=1;loadPage()}
    private func loadPage(reloadMap:Bool=false) {
        cancelPage();ordered=[]
        if reloadMap {tiles=[]}
        guard presentationActive,!busy else {return}
        guard let reference=report?.resultStore else {pageLoading=false;return}
        let id=pageID,flag=LensCancellationFlag(),receiver=LensModelReference(self),workQueue=queue
        let selectedMetric=metric,offset=page*200
        pageToken=flag;pageLoading=true
        pageTask=Task {
            let outcome:Result<LensPageResult,Error>=await withCheckedContinuation {continuation in
                workQueue.async {
                    do {
                        if flag.value {throw CancellationError()}
                        let store=try SpaceLensResultStore(reference:reference)
                        let result=try store.page(offset:offset,metric:selectedMetric,isCancelled:{flag.value})
                        let map=reloadMap ? try store.mapData(metric:selectedMetric,isCancelled:{flag.value}) : nil
                        continuation.resume(returning:.success(.init(page:result,map:map)))
                    } catch {continuation.resume(returning:.failure(error))}
                }
            }
            guard let model=receiver.value,model.pageID==id,model.presentationActive,!flag.value else {return}
            model.pageLoading=false;model.pageTask=nil;model.pageToken=nil
            switch outcome {
            case .success(let result):
                model.ordered=result.page.items;model.totalCount=result.page.totalCount
                if let map=result.map {model.tiles=SpaceLensLayout.rectangles(items:map.items,width:1,height:1,metric:selectedMetric,maxTiles:96,remainingCount:map.remainingCount,remainingBytes:map.remainingBytes)}
            case .failure(let error):model.message="空间分页读取失败："+error.localizedDescription
            }
        }
    }
    private func activateItem(_ item:SpaceLensItem) {
        if item.kind == .directory && ![SpaceLensItemState.skippedCloud,.skippedVolume,.skippedSymlink].contains(item.state) {start(URL(fileURLWithPath:item.path))}
        else {reveal(item.path)}
    }
    func activate(_ path:String?) {
        guard !busy,!pageLoading else {return}
        guard let path else {message="其余项目请在下方分页列表中选择。";return}
        if let item=ordered.first(where:{$0.path==path}) {activateItem(item);return}
        guard let reference=report?.resultStore else {return}
        let id=pageID,receiver=LensModelReference(self),workQueue=queue
        Task {
            let item:SpaceLensItem?=await withCheckedContinuation {continuation in
                workQueue.async {continuation.resume(returning:try? SpaceLensResultStore(reference:reference).item(path:path))}
            }
            guard let model=receiver.value,model.pageID==id,model.presentationActive,!model.busy,let item else {return}
            model.activateItem(item)
        }
    }
    func reveal(_ path:String) {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}
    private func stopPump() {mailbox?.close();mailbox=nil;pump?.cancel();pump=nil}
    func cancel() {
        if let detectionID {taskCenter.markCancelling(detectionID)}
        token?.cancel();stopPump()
        if busy {progressPath="正在取消，等待当前目录操作结束…"}
    }
    func resume() {
        presentationActive=true
        if !busy,report != nil {loadPage(reloadMap:true)}
    }
    func release() {presentationActive=false;cancelPage();ordered=[];tiles=[]}
    func rulesChanged() {
        policyGeneration+=1;cancel();clearReport()
        message="忽略清单已变更，旧空间结果已释放。点击重新分析以应用新范围。"
    }
}
@MainActor
struct SpaceLensView:View {
    @ObservedObject private var model:SpaceLensViewModel
    @ObservedObject private var tasks:DetectionTaskCenter
    init(registry:FeatureStateRegistry?=nil) {
        let registry=registry ?? FeatureStateRegistry.shared
        let controller:SpaceLensViewModel=registry.retain("spaceLens") {SpaceLensViewModel(taskCenter:registry.tasks)}
        _model=ObservedObject(wrappedValue:controller)
        _tasks=ObservedObject(wrappedValue:registry.tasks)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("空间分析").font(.largeTitle.bold())
            Text("点矩形或文件夹进入下一层；点击面包屑返回。只保留当前目录的一页结果，切换目录重新分析。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择目录并分析…") {model.chooseRoot()}.disabled(model.busy || tasks.isBusy)
                Button("上一级") {model.up()}.disabled(model.busy || tasks.isBusy || model.isAtBase)
                Button("重新分析") {model.refresh()}.disabled(model.busy || tasks.isBusy || model.currentRoot==nil)
                Spacer()
                Picker("图形与排序",selection:$model.metric) {ForEach(SpaceLensMetric.allCases) {Text($0.title).tag($0)}}.pickerStyle(.segmented).frame(width:240)
            }
            if !model.breadcrumbs.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) {HStack(spacing:8) {ForEach(model.breadcrumbs) {crumb in
                    Button(crumb.title) {model.start(crumb.url)}.buttonStyle(.link).help(crumb.url.path).disabled(model.busy || tasks.isBusy)
                    if crumb.id != model.breadcrumbs.last?.id {Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary)}
                }}}
            }
            if model.busy {HStack {ProgressView().controlSize(.small);VStack(alignment:.leading) {Text("已检查 \(model.visited) 项");Text(model.progressPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Button("取消") {model.cancel()}}}
            if let report=model.report {
                HStack {
                    Text("已统计逻辑文件量："+Format.bytes(model.logical))
                    Text("分配量："+Format.bytes(model.allocated))
                    Spacer();Text(report.incomplete ? "结果不完整" : "所示范围统计结束").foregroundStyle(report.incomplete ? Color.orange : Color.secondary)
                }.font(.callout)
                if !report.warnings.isEmpty {DisclosureGroup("范围与统计说明（\(report.warnings.count)）") {VStack(alignment:.leading,spacing:4) {ForEach(Array(report.warnings.enumerated()),id:\.offset) {_,warning in Text(warning).font(.caption).foregroundStyle(.secondary)}}}}
                if !model.tiles.isEmpty {spaceMap}
                else {Text("当前没有可绘制的已知正体积。空项、未扫描或跳过项请看列表，不把它们当作已扫描的0占用。").font(.callout).foregroundStyle(.secondary)}
                if model.pageLoading {ProgressView("正在读取磁盘分页…")}
                list
                HStack {
                    Text("\(model.totalCount) 个当前子项 · 第 \(model.page+1)/\(model.pageCount) 页（每页200项）").font(.caption).foregroundStyle(.secondary)
                    Spacer();Button("上一页") {model.previousPage()}.disabled(model.page==0 || model.pageLoading)
                    Button("下一页") {model.nextPage()}.disabled(model.page+1>=model.pageCount || model.pageLoading)
                }
            } else if !model.busy {
                Spacer();Text("选择一个目录开始。不会在打开此页时自动扫描整个主目录。").foregroundStyle(.secondary).frame(maxWidth:.infinity);Spacer()
            }
            Text("逻辑量按文件内容长度，分配量按st_blocks×512并含已遍历目录元数据。硬链接去重；APFS克隆、快照与共享块无法精确归因，分配量不是可释放空间。持续遍历到完成；子项、待办目录及inode记录写入私有临时数据库，每页只读取200项。忽略清单在每次分析入口重新读取。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
        .onAppear {model.resume()}
        .onChange(of:model.metric) {_ in model.rebuild()}
        .onDisappear {model.release()}
        .alert("空间分析",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) {Button("好") {model.message=nil}} message: {Text(model.message ?? "")}
    }
    private var spaceMap:some View {
        GeometryReader {geometry in
            ZStack(alignment:.topLeading) {ForEach(model.tiles) {tile in
                Button {model.activate(tile.path)} label: {
                    ZStack(alignment:.topLeading) {
                        Rectangle().fill(Color(hue:Double(tile.colorIndex)/12,saturation:0.45,brightness:0.63))
                        if geometry.size.width*tile.rect.width>80,geometry.size.height*tile.rect.height>38 {
                            VStack(alignment:.leading,spacing:3) {Text(tile.title).font(.caption.bold()).lineLimit(2);Text(Format.bytes(tile.bytes)).font(.caption2)}.padding(7).foregroundStyle(.white)
                        }
                    }
                }.buttonStyle(.plain).help(tile.title+" · "+Format.bytes(tile.bytes)).disabled(model.busy || tasks.isBusy)
                    .frame(width:max(0,geometry.size.width*tile.rect.width-1),height:max(0,geometry.size.height*tile.rect.height-1))
                    .offset(x:geometry.size.width*tile.rect.x,y:geometry.size.height*tile.rect.y)
            }}
        }.frame(height:250).clipShape(RoundedRectangle(cornerRadius:10))
    }
    private var list:some View {
        ScrollView {
            LazyVStack(spacing:1) {
                ForEach(Array(model.visibleItems)) { item in
                    LensItemRow(item:item,canOpen:!model.busy && !model.pageLoading && !tasks.isBusy,open:{model.activate(item.path)},reveal:{model.reveal(item.path)})
                }
            }
        }
    }
}
private struct LensItemRow:View {
    let item:SpaceLensItem
    let canOpen:Bool
    let open:()->Void
    let reveal:()->Void
    private var symbol:String {item.kind == .directory ? "folder" : item.kind == .symlink ? "link" : "doc"}
    private var statusColor:Color {item.state == .complete ? Color.secondary : Color.orange}
    private var logicalText:String {if let value=item.logicalBytes {return Format.bytes(value)};return "未统计"}
    private var allocatedText:String {if let value=item.allocatedBytes {return Format.bytes(value)};return "未统计"}
    var body:some View {
        HStack(spacing:10) {
            Image(systemName:symbol).foregroundStyle(Color.secondary)
            Button(item.name,action:open).buttonStyle(.link).lineLimit(1).disabled(!canOpen)
            Text(item.state.title).font(.caption).foregroundStyle(statusColor)
            if item.duplicateHardLinks>0 {Text("去重 \(item.duplicateHardLinks) 个链接").font(.caption2).foregroundStyle(Color.secondary)}
            Spacer(minLength:5)
            Text(logicalText).font(.caption.monospacedDigit()).frame(width:100,alignment:.trailing).help("逻辑文件量")
            Text(allocatedText).font(.caption.monospacedDigit()).frame(width:100,alignment:.trailing).help("分配量")
            Button(action:reveal) {Image(systemName:"folder.badge.magnifyingglass")}.buttonStyle(.borderless).help("在Finder显示")
        }.padding(.horizontal,10).padding(.vertical,9).background(Color.white.opacity(0.025)).help(item.path)
    }
}
