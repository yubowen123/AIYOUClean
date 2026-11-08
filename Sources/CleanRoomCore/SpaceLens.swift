import Foundation
import Darwin

public struct SpaceLensLimits:Sendable {
    public var maxEntries:Int
    public var maxSeconds:TimeInterval
    public var maxRSSBytes:UInt64
    public var maxChildren:Int
    public var excludedPaths:[String]
    public var scanToCompletion:Bool
    public init(maxEntries:Int=100_000,maxSeconds:TimeInterval=120,maxRSSBytes:UInt64=512*1024*1024,maxChildren:Int=200,excludedPaths:[String]=[],scanToCompletion:Bool=true) {
        self.maxEntries=max(1,maxEntries);self.maxSeconds=max(0,maxSeconds);self.maxRSSBytes=max(1,maxRSSBytes);self.maxChildren=max(1,min(200,maxChildren));self.excludedPaths=excludedPaths;self.scanToCompletion=scanToCompletion
    }
}
public enum SpaceLensItemKind:String,Codable,Sendable {case file,directory,symlink,other}
public enum SpaceLensItemState:String,Codable,Sendable {
    case complete,partial,unscanned,unreadable,skippedSymlink,skippedCloud,skippedVolume,unsupported
    public var title:String {
        switch self {
        case .complete:return "已完成统计范围"
        case .partial:return "部分统计"
        case .unscanned:return "尚未扫描内容"
        case .unreadable:return "无法读取"
        case .skippedSymlink:return "链接未跟随"
        case .skippedCloud:return "云占位未下载"
        case .skippedVolume:return "其他卷未递归"
        case .unsupported:return "特殊文件未计入"
        }
    }
}
public struct SpaceLensItem:Identifiable,Codable,Sendable,Hashable {
    public let path:String
    public let name:String
    public let kind:SpaceLensItemKind
    public let state:SpaceLensItemState
    public let logicalBytes:Int64?
    public let allocatedBytes:Int64?
    public let fileCount:Int
    public let directoryCount:Int
    public let excludedEntries:Int
    public let duplicateHardLinks:Int
    public var id:String {path}
    public init(path:String,name:String,kind:SpaceLensItemKind,state:SpaceLensItemState,logicalBytes:Int64?,allocatedBytes:Int64?,fileCount:Int=0,directoryCount:Int=0,excludedEntries:Int=0,duplicateHardLinks:Int=0) {
        self.path=path;self.name=name;self.kind=kind;self.state=state;self.logicalBytes=logicalBytes;self.allocatedBytes=allocatedBytes;self.fileCount=fileCount;self.directoryCount=directoryCount;self.excludedEntries=excludedEntries;self.duplicateHardLinks=duplicateHardLinks
    }
}
public struct SpaceLensReport:Sendable {
    public let rootPath:String
    public let startedAt:Date
    public var finishedAt:Date
    public var items:[SpaceLensItem]=[]
    public var warnings:[String]=[]
    public var visitedEntries=0
    public var excludedEntries=0
    public var ignoredEntries=0
    public var duplicateHardLinks=0
    public var incomplete=false
    public var peakRSSBytes:UInt64=0
    public var resultStore:ScanResultReference?
    public var totalItemCount=0
    public var allLogicalBytes:Int64?
    public var allAllocatedBytes:Int64?
    public var logicalBytes:Int64 {allLogicalBytes ?? items.reduce(0) {$0.addingClamped($1.logicalBytes ?? 0)}}
    public var allocatedBytes:Int64 {allAllocatedBytes ?? items.reduce(0) {$0.addingClamped($1.allocatedBytes ?? 0)}}
    public init(rootPath:String,startedAt:Date=Date()) {self.rootPath=rootPath;self.startedAt=startedAt;finishedAt=startedAt}
}
public enum SpaceLensMetric:String,CaseIterable,Identifiable,Sendable {
    case allocated,logical
    public var id:String {rawValue}
    public var title:String {self == .allocated ? "分配量" : "逻辑文件量"}
    public func bytes(_ item:SpaceLensItem) -> Int64? {self == .allocated ? item.allocatedBytes : item.logicalBytes}
}
private extension Int64 {
    func addingClamped(_ other:Int64) -> Int64 {let (value,overflow)=addingReportingOverflow(other);return overflow ? Int64.max : value}
}
private struct LensAccumulator {
    let path:String
    let name:String
    var kind:SpaceLensItemKind
    var state:SpaceLensItemState
    var logical:Int64=0
    var allocated:Int64=0
    var files=0
    var directories=0
    var excluded=0
    var hardLinks=0
    var item:SpaceLensItem {
        let unknown:[SpaceLensItemState]=[.unscanned,.unreadable,.skippedSymlink,.skippedCloud,.skippedVolume,.unsupported]
        let hasValues = !unknown.contains(state)
        return .init(path:path,name:name,kind:kind,state:state,logicalBytes:hasValues ? logical : nil,allocatedBytes:hasValues ? allocated : nil,fileCount:files,directoryCount:directories,excludedEntries:excluded,duplicateHardLinks:hardLinks)
    }
}
public final class SpaceLensService:Sendable {
    public init() {}
    public func scan(root:URL,limits:SpaceLensLimits = .init(),home:URL=FileManager.default.homeDirectoryForCurrentUser,isCancelled:@escaping @Sendable ()->Bool={false},progress:@escaping @Sendable (Int,String)->Void={_,_ in}) -> SpaceLensReport {
        let clean=root.standardizedFileURL
        guard let permit=WorkBudget.tryAcquire("目录空间分析") else {var r=SpaceLensReport(rootPath:clean.path);r.incomplete=true;r.warnings=["另一项扫描、检测或维护任务正在运行，请稍后分析空间。"];return r}
        defer {permit.release()}
        do {
            let saved=try IgnoreRuleStore(home:home).load()
            let rules=try IgnoreRuleStore.normalize(Array(Set(saved+limits.excludedPaths)))
            let work=LensWalk(root:clean,limits:limits,rules:rules,cancelled:isCancelled,progress:progress)
            return work.run()
        } catch {var r=SpaceLensReport(rootPath:clean.path);r.incomplete=true;r.finishedAt=Date();r.warnings=["忽略配置不可用，未扫描："+error.localizedDescription];return r}
    }
}
private final class LensWalk {
    let root:URL
    let limits:SpaceLensLimits
    let rules:[(path:String,prefix:String)]
    let cancelled:@Sendable ()->Bool
    let progress:@Sendable (Int,String)->Void
    var report:SpaceLensReport
    var store:SpaceLensResultStore?
    // One direct child accumulator. Every other child, directory queue entry,
    // directory inode and hardlink owner is stored in SQLite's bounded cache.
    var current=LensAccumulator(path:"",name:"",kind:.other,state:.unscanned)
    var device:UInt64=0
    var stopReason:String?
    var lastProgress=Date.distantPast
    var lastRSS=Date.distantPast
    let deadline:Date
    init(root:URL,limits:SpaceLensLimits,rules:[String],cancelled:@escaping @Sendable ()->Bool,progress:@escaping @Sendable(Int,String)->Void) {
        self.root=root;self.limits=limits;self.rules=rules.map {($0,$0=="/" ? "/" : $0+"/")};self.cancelled=cancelled;self.progress=progress
        report=SpaceLensReport(rootPath:root.path);deadline=Date().addingTimeInterval(limits.maxSeconds.isFinite ? limits.maxSeconds : 1e12)
    }
    func warn(_ message:String) {if report.warnings.count<40,!report.warnings.contains(message) {report.warnings.append(message)}}
    func stopped(forceRSS:Bool=false) -> Bool {
        if stopReason != nil {return true}
        if cancelled() {stopReason="分析已取消，结果仅覆盖已扫描部分。"}
        else if !limits.scanToCompletion,Date()>=deadline {stopReason="诊断模式达到空间分析时间上限，结果不完整。"}
        else if !limits.scanToCompletion,report.visitedEntries>=limits.maxEntries {stopReason="诊断模式达到遍历上限，结果不完整。"}
        if forceRSS || Date().timeIntervalSince(lastRSS)>=0.2 {
            lastRSS=Date()
            if let rss=ProcessResources.residentBytes() {
                report.peakRSSBytes=max(report.peakRSSBytes,rss)
                if !limits.scanToCompletion,rss>=limits.maxRSSBytes {stopReason="诊断模式达到RSS参考阈值，已停止空间分析。"}
            } else if !limits.scanToCompletion {stopReason="诊断模式无法读取进程RSS。"}
        }
        return stopReason != nil
    }
    func excluded(_ path:String) -> Bool {rules.contains {path==$0.path || path.hasPrefix($0.prefix)}}
    func visit(_ path:String) {
        report.visitedEntries+=1
        if report.visitedEntries%128==0,Date().timeIntervalSince(lastProgress)>=0.1 {lastProgress=Date();progress(report.visitedEntries,path)}
    }
    func run() -> SpaceLensReport {
        guard !excluded(root.path) else {report.incomplete=true;report.ignoredEntries=1;warn("根目录位于忽略清单，未扫描；未扫描不是0占用。");return finish()}
        guard !FileSafety.hasSymlinkComponent(root) else {report.incomplete=true;warn("根路径含符号链接，未跟随。请选择实际目录。");return finish()}
        var metadata=stat()
        guard lstat(root.path,&metadata)==0,metadata.st_mode&S_IFMT==S_IFDIR else {report.incomplete=true;warn("根路径不存在、不可访问或不是目录。");return finish()}
        guard metadata.st_flags&UInt32(SF_DATALESS)==0 else {report.incomplete=true;warn("根目录为云端占位对象，未请求下载或读取其内容。");return finish()}
        device=UInt64(metadata.st_dev)
        guard !stopped(forceRSS:true) else {return finish()}
        guard let directory=opendir(root.path) else {report.incomplete=true;warn("无法打开所选目录，可能没有访问权限。");return finish()}
        defer {closedir(directory)}
        do {
            let source=try SpaceLensResultStore.create();store=source;report.resultStore=source.reference
            _ = try source.markDirectory(device:device,inode:UInt64(metadata.st_ino))
            while !stopped() {
                let more=try autoreleasepool {() throws -> Bool in
                    errno=0
                    guard let entry=readdir(directory) else {if errno != 0 {report.incomplete=true;warn("读取根目录时出现文件系统错误。")};return false}
                    let name=entryName(entry)
                    if name=="." || name==".." {return true}
                    let path=root.path.hasSuffix("/") ? root.path+name : root.path+"/"+name
                    visit(path)
                    if excluded(path) {report.ignoredEntries+=1;report.excludedEntries+=1;return true}
                    current=LensAccumulator(path:path,name:name,kind:.other,state:.unreadable)
                    var info=stat()
                    guard lstat(path,&info)==0 else {report.incomplete=true;try source.save(current.item);return true}
                    let kind=info.st_mode&S_IFMT
                    current.kind=kind==S_IFDIR ? .directory : kind==S_IFREG ? .file : kind==S_IFLNK ? .symlink : .other
                    if kind==S_IFLNK {current.state = .skippedSymlink;report.excludedEntries+=1}
                    else if info.st_flags&UInt32(SF_DATALESS) != 0 {current.state = .skippedCloud;report.excludedEntries+=1}
                    else if UInt64(info.st_dev) != device {current.state = .skippedVolume;report.excludedEntries+=1}
                    else if kind==S_IFREG {current.state = .complete;try accountFile(info)}
                    else if kind==S_IFDIR {
                        current.state = .partial;current.allocated=allocated(info);current.directories=1
                        if try source.markDirectory(device:device,inode:UInt64(info.st_ino)) {
                            try source.enqueue(path)
                            while !stopped(),let next=try autoreleasepool(invoking:{try source.popDirectory()}) {try readDirectory(next)}
                            if !stopped(),current.excluded==0 {current.state = .complete}
                        } else {current.excluded+=1;report.excludedEntries+=1}
                    } else {current.state = .unsupported;report.excludedEntries+=1}
                    try source.save(current.item)
                    current=LensAccumulator(path:"",name:"",kind:.other,state:.unscanned)
                    return true
                }
                if !more {break}
            }
        } catch {
            report.incomplete=true
            stopReason="空间结果或目录队列无法继续写入；可能磁盘空间不足或文件系统出错："+error.localizedDescription
            if !current.path.isEmpty {current.state = .partial;try? store?.save(current.item)}
        }
        return finish()
    }
    func readDirectory(_ path:String) throws {
        guard !stopped() else {return}
        let safe=autoreleasepool {!FileSafety.hasSymlinkComponent(URL(fileURLWithPath:path))}
        var rootInfo=stat()
        guard safe,lstat(path,&rootInfo)==0,rootInfo.st_mode&S_IFMT==S_IFDIR,UInt64(rootInfo.st_dev)==device,
              rootInfo.st_flags&UInt32(SF_DATALESS)==0,let directory=opendir(path) else {
            current.excluded+=1;report.incomplete=true;warn("部分目录无法读取、被系统拒绝访问或在扫描期间发生变化。");return
        }
        defer {closedir(directory)}
        while !stopped() {
            let more=try autoreleasepool {() throws -> Bool in
                errno=0
                guard let entry=readdir(directory) else {if errno != 0 {current.excluded+=1;report.incomplete=true;warn("遍历部分目录时出现文件系统错误。")};return false}
                let name=entryName(entry)
                if name=="." || name==".." {return true}
                let next=path.hasSuffix("/") ? path+name : path+"/"+name
                visit(next)
                if excluded(next) {current.excluded+=1;report.ignoredEntries+=1;report.excludedEntries+=1;return true}
                var info=stat()
                guard lstat(next,&info)==0 else {current.excluded+=1;report.incomplete=true;return true}
                let kind=info.st_mode&S_IFMT
                guard kind != S_IFLNK,info.st_flags&UInt32(SF_DATALESS)==0,UInt64(info.st_dev)==device else {current.excluded+=1;report.excludedEntries+=1;return true}
                if kind==S_IFREG {try accountFile(info)}
                else if kind==S_IFDIR {
                    guard let store,try store.markDirectory(device:device,inode:UInt64(info.st_ino)) else {current.excluded+=1;report.excludedEntries+=1;return true}
                    current.directories+=1;current.allocated=current.allocated.addingClamped(allocated(info));try store.enqueue(next)
                } else {current.excluded+=1;report.excludedEntries+=1}
                return true
            }
            if !more {break}
        }
    }
    func accountFile(_ info:stat) throws {
        current.files+=1
        let logical=max(0,Int64(info.st_size)),blocks=allocated(info)
        if info.st_nlink>1,let store {
            let result=try store.accountHardLink(device:UInt64(info.st_dev),inode:UInt64(info.st_ino),owner:current.path,logical:logical,allocated:blocks)
            if result.duplicate {report.duplicateHardLinks+=1}
            if !result.counted {current.hardLinks+=1;return}
        }
        current.logical=current.logical.addingClamped(logical);current.allocated=current.allocated.addingClamped(blocks)
    }
    func finish() -> SpaceLensReport {
        if let stopReason {report.incomplete=true;warn(stopReason)}
        if let store {
            do {
                try store.flush()
                let statistics=try store.statistics()
                report.totalItemCount=statistics.totalCount;report.allLogicalBytes=statistics.logicalBytes;report.allAllocatedBytes=statistics.allocatedBytes
                if statistics.incompleteCount>0 {report.incomplete=true}
                report.items=try store.page(limit:limits.maxChildren).items
            } catch {report.incomplete=true;warn("部分落盘结果无法读取："+error.localizedDescription)}
        }
        if report.excludedEntries>0 || report.ignoredEntries>0 {warn("已跳过链接、云占位、其他卷、特殊文件或忽略项；这些对象未纳入所示体积。")}
        if report.duplicateHardLinks>0 {warn("硬链接按设备号/inode落盘去重，归属到字典序较前的当前目录子项；不等于逐目录单独扫描的体积。")}
        warn("分配量来自st_blocks×512，含已遍历目录元数据；APFS克隆/压缩/快照与共享块不能据此精确归因，不等于可释放空间。")
        report.finishedAt=Date();progress(report.visitedEntries,root.path)
        return report
    }
    func allocated(_ info:stat) -> Int64 {let blocks=max(0,Int64(info.st_blocks));return blocks>Int64.max/512 ? Int64.max : blocks*512}
    func entryName(_ pointer:UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to:pointer.pointee.d_name) {name in name.withMemoryRebound(to:CChar.self,capacity:MemoryLayout.size(ofValue:pointer.pointee.d_name)) {String(cString:$0)}}
    }
}

public struct SpaceLensRect:Hashable,Sendable {public let x:Double;public let y:Double;public let width:Double;public let height:Double;public var area:Double {width*height}}
public struct SpaceLensTile:Identifiable,Hashable,Sendable {
    public let id:String
    public let path:String?
    public let title:String
    public let bytes:Int64
    public let rect:SpaceLensRect
    public let colorIndex:Int
}
public enum SpaceLensLayout {
    public static func rectangles(items:[SpaceLensItem],width:Double,height:Double,metric:SpaceLensMetric = .allocated,maxTiles:Int=96,remainingCount:Int=0,remainingBytes:Int64=0) -> [SpaceLensTile] {
        guard width.isFinite,height.isFinite,width>0,height>0 else {return []}
        let cap=max(1,min(128,maxTiles))
        let weighted=items.compactMap {item -> (SpaceLensItem,Int64)? in guard let bytes=metric.bytes(item),bytes>0 else {return nil};return (item,bytes)}.sorted {$0.1==$1.1 ? $0.0.path<$1.0.path : $0.1>$1.1}
        guard !weighted.isEmpty || remainingBytes>0 else {return []}
        var values:[(String,String?,String,Int64)]=[]
        let needsAggregate=weighted.count>cap || remainingBytes>0
        let count=needsAggregate ? min(weighted.count,max(0,cap-1)) : weighted.count
        values=weighted.prefix(count).map {($0.0.id,$0.0.path,$0.0.name,$0.1)}
        let remainder=weighted.dropFirst(count),sum=remainder.reduce(max(0,remainingBytes)) {$0.addingClamped($1.1)}
        if sum>0 {values.append(("space-lens-other",nil,"其他 \(remainder.count+max(0,remainingCount)) 项",sum))}
        var result:[SpaceLensTile]=[]
        func layout(_ start:Int,_ end:Int,_ rect:SpaceLensRect) {
            guard end>start else {return}
            if end-start==1 {let value=values[start];result.append(.init(id:value.0,path:value.1,title:value.2,bytes:value.3,rect:rect,colorIndex:start%12));return}
            // Each split uses one bounded range reduction; no row asks for the whole report's total.
            let total=values[start..<end].reduce(0.0) {$0+Double($1.3)}
            var first=0.0,split=start+1
            for index in start..<(end-1) {first+=Double(values[index].3);split=index+1;if first>=total/2 {break}}
            let fraction=max(0,min(1,first/total))
            if rect.width>=rect.height {
                let cut=rect.width*fraction
                layout(start,split,.init(x:rect.x,y:rect.y,width:cut,height:rect.height));layout(split,end,.init(x:rect.x+cut,y:rect.y,width:max(0,rect.width-cut),height:rect.height))
            } else {
                let cut=rect.height*fraction
                layout(start,split,.init(x:rect.x,y:rect.y,width:rect.width,height:cut));layout(split,end,.init(x:rect.x,y:rect.y+cut,width:rect.width,height:max(0,rect.height-cut)))
            }
        }
        layout(0,values.count,.init(x:0,y:0,width:width,height:height));return result
    }
}
