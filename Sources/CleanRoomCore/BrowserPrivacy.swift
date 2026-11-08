import Foundation
import AppKit
import CryptoKit
import CSQLite

public enum PrivacyBrowser:String,Codable,CaseIterable,Sendable {
    case chrome,firefox
    public var title:String { self == .chrome ? "Google Chrome" : "Firefox" }
    fileprivate var bundleID:String { self == .chrome ? "com.google.Chrome" : "org.mozilla.firefox" }
}
public enum BrowserPrivacyCategory:String,Codable,CaseIterable,Sendable {
    case chromeHistory,chromeDownloads,chromeCookies,firefoxHistory,firefoxDownloads,firefoxCookies
    public var browser:PrivacyBrowser { rawValue.hasPrefix("chrome") ? .chrome : .firefox }
    public var title:String {
        switch self {
        case .chromeHistory:return "浏览历史"
        case .chromeDownloads:return "下载记录（不删除下载文件）"
        case .chromeCookies,.firefoxCookies:return "Cookies（可能退出网站登录）"
        case .firefoxHistory:return "访问事件（保留URL与书签结构）"
        case .firefoxDownloads:return "下载事件与注释（不删除文件）"
        }
    }
}
public struct BrowserPrivacyItem:Identifiable,Codable,Sendable {
    public let path:String
    public let profile:String
    public let category:BrowserPrivacyCategory
    public let records:Int64
    public let tableCounts:[String:Int64]
    public let identity:FileIdentity
    public let walIdentity:FileIdentity?
    public let profileRoot:String
    public var id:String { category.rawValue+":"+path }
}
public struct BrowserPrivacyReport:Sendable {
    public var items:[BrowserPrivacyItem]=[]
    public var warnings:[String]=[]
    public var truncated=false
    public init() {}
}
public enum PrivacyBackupState:String,Codable,Sendable { case backedUp,cleared }
public struct BrowserPrivacyBackupReceipt:Identifiable,Codable,Sendable {
    public let id:UUID
    public let date:Date
    public let browser:PrivacyBrowser
    public let originalPath:String
    public let backupPath:String
    public let categories:[BrowserPrivacyCategory]
    public let sha256:String
    public let backupIdentity:FileIdentity
    public var state:PrivacyBackupState
    public var deletedRecords:[String:Int64]
}
public struct BrowserPrivacyClearResult:Sendable {
    public var receipts:[BrowserPrivacyBackupReceipt]=[]
    public var errors:[String]=[]
    public var cancelled=false
    public var deletedRecords:Int64 { receipts.reduce(0) { $0+$1.deletedRecords.values.reduce(0,+) } }
    public init() {}
}
public enum BrowserPrivacyError:LocalizedError {
    case rejected(String)
    public var errorDescription:String? { if case .rejected(let message)=self {return message};return nil }
}
private final class PrivacySQLiteContext {
    let deadline:Date
    let cancelled:() -> Bool
    var allowedWriteTables:Set<String>?
    init(seconds:Double,cancelled:@escaping ()->Bool) { deadline=Date().addingTimeInterval(seconds);self.cancelled=cancelled }
    var stopped:Bool { cancelled() || Date()>deadline }
}
private let privacySQLiteProgress:@convention(c)(UnsafeMutableRawPointer?) -> Int32 = { pointer in
    guard let pointer else { return 0 }
    return Unmanaged<PrivacySQLiteContext>.fromOpaque(pointer).takeUnretainedValue().stopped ? 1 : 0
}
private let privacySQLiteAuthorizer:@convention(c)(UnsafeMutableRawPointer?,Int32,UnsafePointer<CChar>?,UnsafePointer<CChar>?,UnsafePointer<CChar>?,UnsafePointer<CChar>?) -> Int32 = { pointer,action,table,_,_,_ in
    guard let pointer else {return SQLITE_DENY}
    let context=Unmanaged<PrivacySQLiteContext>.fromOpaque(pointer).takeUnretainedValue()
    if action==SQLITE_DELETE || action==SQLITE_UPDATE || action==SQLITE_INSERT {
        guard let table,let allowed=context.allowedWriteTables,allowed.contains(String(cString:table)) else {return SQLITE_DENY}
    }
    if action==SQLITE_ATTACH || action==SQLITE_DETACH {return SQLITE_DENY}
    return SQLITE_OK
}
private final class PrivacyDB {
    var pointer:OpaquePointer?
    private let context:PrivacySQLiteContext
    init(_ path:String,write:Bool,create:Bool=false,cancelled:@escaping ()->Bool={false},seconds:Double=20) throws {
        context=PrivacySQLiteContext(seconds:seconds,cancelled:cancelled)
        var flags=(write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        if create { flags |= SQLITE_OPEN_CREATE }
        guard sqlite3_open_v2(path,&pointer,flags,nil)==SQLITE_OK else { if pointer != nil {sqlite3_close(pointer)};pointer=nil;throw BrowserPrivacyError.rejected("无法打开浏览器数据库（文件被占用、不可访问或不是SQLite）") }
        sqlite3_busy_timeout(pointer,250)
        sqlite3_progress_handler(pointer,10_000,privacySQLiteProgress,Unmanaged.passUnretained(context).toOpaque())
        do {
            try exec("PRAGMA cache_size=-2048");try exec("PRAGMA mmap_size=0");try exec("PRAGMA temp_store=FILE")
            try exec("PRAGMA trusted_schema=OFF");try exec("PRAGMA foreign_keys=ON")
            if !write {try exec("PRAGMA query_only=ON")}
        } catch { sqlite3_close(pointer);pointer=nil;throw error }
    }
    deinit { if let pointer {sqlite3_progress_handler(pointer,0,nil,nil);sqlite3_close(pointer)} }
    var stopped:Bool {context.stopped}
    func exec(_ sql:String) throws {
        guard sqlite3_exec(pointer,sql,nil,nil,nil)==SQLITE_OK else { throw BrowserPrivacyError.rejected(stopped ? "数据库操作已取消或达到时间上限" : "数据库操作失败（忙碌、Schema不兼容或约束未满足），未继续") }
    }
    func scalar(_ sql:String) throws -> Int64 {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(pointer,sql,-1,&statement,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("数据库Schema不受支持，未读取正文")}
        defer {sqlite3_finalize(statement)}
        guard sqlite3_step(statement)==SQLITE_ROW else {throw BrowserPrivacyError.rejected(stopped ? "统计已取消或超时" : "数据库计数失败")}
        return sqlite3_column_int64(statement,0)
    }
    func columns(_ table:String) throws -> Set<String> {
        guard BrowserPrivacyService.allowedTables.contains(table) else {throw BrowserPrivacyError.rejected("非白名单数据表")}
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(pointer,"PRAGMA table_info(\"\(table)\")",-1,&statement,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("无法验证数据库Schema")}
        defer {sqlite3_finalize(statement)}
        var columns=Set<String>(),rows=0
        while true {
            let status=sqlite3_step(statement)
            if status==SQLITE_DONE {break}
            guard status==SQLITE_ROW,rows<256,let name=sqlite3_column_text(statement,1) else {throw BrowserPrivacyError.rejected("Schema字段数量超限或损坏")}
            columns.insert(String(cString:name));rows+=1
        }
        return columns
    }
    func require(_ table:String,_ columns:Set<String>) throws {
        guard columns.isSubset(of:try self.columns(table)) else {throw BrowserPrivacyError.rejected("数据库Schema与白名单规则不匹配："+table)}
    }
    func integrity() throws {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(pointer,"PRAGMA quick_check(1)",-1,&s,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("无法检查数据库一致性")}
        defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_ROW,let value=sqlite3_column_text(s,0),String(cString:value)=="ok" else {throw BrowserPrivacyError.rejected("数据库一致性检查未通过")}
    }
    func authorizeWrites(_ tables:Set<String>) {
        context.allowedWriteTables=tables
        sqlite3_set_authorizer(pointer,privacySQLiteAuthorizer,Unmanaged.passUnretained(context).toOpaque())
    }
    func foreignKeys() throws {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(pointer,"PRAGMA foreign_key_check",-1,&s,nil)==SQLITE_OK else {throw BrowserPrivacyError.rejected("无法验证数据库引用关系")}
        defer {sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_DONE else {throw BrowserPrivacyError.rejected("数据库引用关系检查未通过，未提交")}
    }
    func rollback() {sqlite3_progress_handler(pointer,0,nil,nil);_ = sqlite3_exec(pointer,"ROLLBACK",nil,nil,nil)}
}
private struct PrivacyPlan {
    let category:BrowserPrivacyCategory
    let counts:[String:String]
    let deletes:[(String,String)]
    let updates:[String]
    var tables:Set<String> {Set(deletes.map(\.0))}
}

public final class BrowserPrivacyService:@unchecked Sendable {
    public let storageRoot:URL
    private let browserRunning:@Sendable (PrivacyBrowser)->Bool
    fileprivate static let allowedTables:Set<String>=["urls","visits","visit_source","keyword_search_terms","segments","segment_usage","downloads","downloads_url_chains","cookies","moz_historyvisits","moz_places","moz_bookmarks","moz_annos","moz_anno_attributes","moz_cookies","moz_origins"]
    public init(storageRoot:URL?=nil,browserRunning:@escaping @Sendable (PrivacyBrowser)->Bool={BrowserPrivacyService.isBrowserRunning($0)}) {
        self.storageRoot=storageRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIYOUClean/PrivacyBackups")
        self.browserRunning=browserRunning
    }
    public static func isBrowserRunning(_ browser:PrivacyBrowser) -> Bool {
        let apps=NSWorkspace.shared.runningApplications
        if apps.contains(where: { let id=$0.bundleIdentifier ?? "";return id.hasPrefix(browser.bundleID) }) {return true}
        let list=CommandRunner.run("/bin/ps",["-axo","comm="],timeout:3)
        // Fail closed if helper-state inspection is unavailable; never print the process list.
        guard list.code==0,list.output.utf8.count<1_048_576 else {return true}
        let needles=browser == .chrome ? ["/Google Chrome.app/Contents/","Google Chrome Helper.app/Contents/"] : ["/Firefox.app/Contents/","/plugin-container"]
        return list.output.split(separator:"\n").contains {line in needles.contains(where:{line.contains($0)})}
    }
    public func scan(home:URL=FileManager.default.homeDirectoryForCurrentUser,profileRoots:[URL]=[],isCancelled:@escaping @Sendable ()->Bool={false}) -> BrowserPrivacyReport {
        guard let permit=WorkBudget.tryAcquire("统计浏览器隐私数据库") else {var r=BrowserPrivacyReport();r.warnings=["另一项重任务正在运行，请稍后统计浏览器数据"];return r}
        defer {permit.release()}
        var report=BrowserPrivacyReport(),profiles:[(URL,PrivacyBrowser)]=[]
        let roots=profileRoots.isEmpty ? [(home.appendingPathComponent("Library/Application Support/Google/Chrome"),PrivacyBrowser.chrome),(home.appendingPathComponent("Library/Application Support/Firefox/Profiles"),PrivacyBrowser.firefox)] : profileRoots.map {($0,$0.path.contains("Firefox") ? PrivacyBrowser.firefox : PrivacyBrowser.chrome)}
        let deadline=Date().addingTimeInterval(45)
        for (parent,browser) in roots {
            if isCancelled() || Date()>deadline {report.truncated=true;break}
            guard !FileSafety.hasSymlinkComponent(parent),FileManager.default.fileExists(atPath:parent.path),let e=FileManager.default.enumerator(at:parent,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsPackageDescendants,.skipsHiddenFiles],errorHandler:{_,_ in false}) else {continue}
            for case let u as URL in e {
                e.skipDescendants()
                if isCancelled() || Date()>deadline {report.truncated=true;break}
                guard profiles.count<30 else {report.truncated=true;break}
                let values=try? u.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values?.isDirectory==true,values?.isSymbolicLink != true else {continue}
                if browser == .chrome && !(u.lastPathComponent=="Default" || u.lastPathComponent.hasPrefix("Profile ")) {continue}
                profiles.append((u,browser))
            }
        }
        for (profile,browser) in profiles {
            if isCancelled() || Date()>deadline {report.truncated=true;break}
            autoreleasepool {
                let candidates:[(URL,[BrowserPrivacyCategory])]
                if browser == .chrome {
                    candidates=[(profile.appendingPathComponent("History"),[.chromeHistory,.chromeDownloads]),(profile.appendingPathComponent("Network/Cookies"),[.chromeCookies]),(profile.appendingPathComponent("Cookies"),[.chromeCookies])]
                } else {candidates=[(profile.appendingPathComponent("places.sqlite"),[.firefoxHistory,.firefoxDownloads]),(profile.appendingPathComponent("cookies.sqlite"),[.firefoxCookies])]}
                for (file,categories) in candidates {
                    guard report.items.count<100 else {report.truncated=true;break}
                    guard FileManager.default.fileExists(atPath:file.path) else {continue}
                    do {
                        try validatePath(file,profileRoot:profile.path)
                        guard let before=FileSafety.identity(file) else {throw BrowserPrivacyError.rejected("无法读取数据库身份")}
                        let walBefore=FileSafety.identity(URL(fileURLWithPath:file.path+"-wal"))
                        let db=try PrivacyDB(file.path,write:false,cancelled:isCancelled,seconds:10)
                        try db.exec("BEGIN")
                        var items:[BrowserPrivacyItem]=[]
                        for category in categories {
                            let plan=try plan(category,db:db)
                            var counts:[String:Int64]=[:]
                            for (name,sql) in plan.counts {counts[name]=try db.scalar(sql)}
                            items.append(BrowserPrivacyItem(path:file.path,profile:profile.lastPathComponent,category:category,records:counts.values.reduce(0,+),tableCounts:counts,identity:before,walIdentity:walBefore,profileRoot:profile.path))
                        }
                        try db.exec("COMMIT")
                        guard before==FileSafety.identity(file),walBefore==FileSafety.identity(URL(fileURLWithPath:file.path+"-wal")) else {throw BrowserPrivacyError.rejected("统计期间数据库发生变化，请退出浏览器后重新统计")}
                        let available=max(0,100-report.items.count)
                        report.items.append(contentsOf:items.prefix(available))
                        if items.count>available {report.truncated=true}
                    } catch {if report.warnings.count<40 {report.warnings.append(browser.title+" / "+profile.lastPathComponent+" / "+file.lastPathComponent+"："+error.localizedDescription)}}
                }
            }
        }
        if report.truncated || isCancelled() {report.truncated=true;report.warnings.append("统计因取消、时间、30个profile或100项上限而不完整。")}
        report.warnings.append("只读取Schema和COUNT，不显示URL、标题、cookie值或下载路径。同步账号可能重新带回记录。Firefox保留URL与书签结构，不等于清除所有浏览痕迹。")
        return report
    }
    public func clear(_ selected:[BrowserPrivacyItem],confirmed:Bool,isCancelled:@escaping @Sendable ()->Bool={false}) -> BrowserPrivacyClearResult {
        var result=BrowserPrivacyClearResult()
        guard confirmed else {result.errors=["尚未确认具体数据库与类别"];return result}
        guard selected.count<=100 else {result.errors=["选择超过100项，请分批处理"];return result}
        guard let permit=WorkBudget.tryAcquire("清理浏览器隐私数据库") else {result.errors=["另一项扫描、检测或维护任务正在运行"];return result}
        defer {permit.release()}
        var grouped:[String:[BrowserPrivacyItem]]=[:]
        for item in selected {if !grouped[item.path,default:[]].contains(where:{$0.category==item.category}) {grouped[item.path,default:[]].append(item)}}
        for (path,items) in grouped.sorted(by:{$0.key<$1.key}) {
            if isCancelled() {result.cancelled=true;break}
            do {
                let (receipt,warning)=try clearDatabase(path,items:items,isCancelled:isCancelled)
                result.receipts.append(receipt)
                if let warning {result.errors.append(warning)}
            } catch {result.errors.append(URL(fileURLWithPath:path).lastPathComponent+"："+error.localizedDescription)}
        }
        if isCancelled() {result.cancelled=true}
        return result
    }
    public func receipts() -> [BrowserPrivacyBackupReceipt] {
        guard !FileSafety.hasSymlinkComponent(storageRoot),let e=FileManager.default.enumerator(at:storageRoot,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey],options:[.skipsHiddenFiles]) else {return []}
        var records:[BrowserPrivacyBackupReceipt]=[],visited=0
        for case let u as URL in e {
            visited+=1;if visited>1000 || records.count>=100 {break}
            guard u.pathExtension=="json",!FileSafety.hasSymlinkComponent(u),let values=try? u.resourceValues(forKeys:[.fileSizeKey]),(values.fileSize ?? Int.max)<65_536,let data=try? Data(contentsOf:u),let record=try? JSONDecoder().decode(BrowserPrivacyBackupReceipt.self,from:data) else {continue}
            records.append(record)
        }
        return records.sorted {$0.date>$1.date}
    }
    public func exportBackup(_ receipt:BrowserPrivacyBackupReceipt,to destination:URL,confirmed:Bool) throws {
        guard confirmed else {throw BrowserPrivacyError.rejected("尚未确认导出备份副本")}
        guard let permit=WorkBudget.tryAcquire("导出浏览器隐私备份") else {throw BrowserPrivacyError.rejected("另一项重任务正在运行")}
        defer {permit.release()}
        let backup=URL(fileURLWithPath:receipt.backupPath).standardizedFileURL
        guard FileSafety.contains(storageRoot.standardizedFileURL.path,backup.path),!FileSafety.hasSymlinkComponent(backup),FileSafety.identity(backup)==receipt.backupIdentity,try hash(backup)==receipt.sha256 else {throw BrowserPrivacyError.rejected("备份文件已变化或不属于本应用备份目录")}
        guard !FileManager.default.fileExists(atPath:destination.path),!FileSafety.hasSymlinkComponent(destination),!FileSafety.hasSymlinkComponent(destination.deletingLastPathComponent()),destination.standardizedFileURL.path != receipt.originalPath else {throw BrowserPrivacyError.rejected("导出目标必须为全新文件，不能覆盖原数据库或现有文件")}
        try FileManager.default.copyItem(at:backup,to:destination)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
    }
    private func clearDatabase(_ path:String,items:[BrowserPrivacyItem],isCancelled:@escaping @Sendable ()->Bool) throws -> (BrowserPrivacyBackupReceipt,String?) {
        guard let first=items.first,items.allSatisfy({$0.category.browser==first.category.browser && $0.profileRoot==first.profileRoot}) else {throw BrowserPrivacyError.rejected("数据库选择不一致")}
        guard !browserRunning(first.category.browser) else {throw BrowserPrivacyError.rejected("请完全退出 "+first.category.browser.title+" 及其后台进程后重新统计")}
        let file=URL(fileURLWithPath:path)
        try validatePath(file,profileRoot:first.profileRoot)
        guard FileSafety.identity(file)==first.identity,FileSafety.identity(URL(fileURLWithPath:path+"-wal"))==first.walIdentity else {throw BrowserPrivacyError.rejected("数据库或WAL在统计后变化，请重新统计")}
        let db=try PrivacyDB(path,write:true,cancelled:isCancelled,seconds:30)
        try db.exec("BEGIN IMMEDIATE")
        var committed=false
        defer {if !committed {db.rollback()}}
        var plans:[PrivacyPlan]=[]
        for item in items {
            let p=try plan(item.category,db:db)
            var counts:[String:Int64]=[:];for (name,sql) in p.counts {counts[name]=try db.scalar(sql)}
            guard counts==item.tableCounts else {throw BrowserPrivacyError.rejected("数据记录数已变化，请重新统计")}
            plans.append(p)
        }
        try db.foreignKeys()
        let touched=plans.reduce(into:Set<String>()) {$0.formUnion($1.tables)}
        // Never execute persistent custom triggers while modifying another product's database.
        for table in touched {guard try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='\(table)'")==0 else {throw BrowserPrivacyError.rejected("发现持久自定义触发器，使用浏览器自身清理流程")}}
        if items.contains(where:{$0.category == .firefoxHistory || $0.category == .firefoxDownloads}) {guard try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name IN ('moz_places','moz_origins')")==0 else {throw BrowserPrivacyError.rejected("Firefox存在不支持的持久维护触发器")}}
        let folder=try backupDirectory();let id=UUID();let backup=folder.appendingPathComponent(id.uuidString+".sqlite")
        try requireDisk(file,backupDirectory:folder)
        do {try onlineBackup(source:path,to:backup,isCancelled:isCancelled)} catch {try? FileManager.default.removeItem(at:backup);throw error}
        guard let identity=FileSafety.identity(backup) else {throw BrowserPrivacyError.rejected("无法核验备份身份")}
        var receipt=BrowserPrivacyBackupReceipt(id:id,date:Date(),browser:first.category.browser,originalPath:path,backupPath:backup.path,categories:items.map(\.category),sha256:try hash(backup),backupIdentity:identity,state:.backedUp,deletedRecords:[:])
        let record=folder.appendingPathComponent(id.uuidString+".json")
        try save(receipt,to:record)
        guard !isCancelled(),!browserRunning(first.category.browser) else {throw BrowserPrivacyError.rejected("已备份，但用户取消或浏览器重新启动；未清理")}
        var allowed=touched
        if items.contains(where:{$0.category == .firefoxHistory || $0.category == .firefoxDownloads}) {allowed.formUnion(["moz_places","moz_origins"])}
        db.authorizeWrites(allowed)
        var statements=Set<String>()
        for plan in plans {
            for (table,sql) in plan.deletes where statements.insert(sql).inserted {
                try db.exec(sql);receipt.deletedRecords[table,default:0]+=Int64(sqlite3_changes(db.pointer))
            }
        }
        for plan in plans {for sql in plan.updates where statements.insert(sql).inserted {try db.exec(sql)}}
        try db.integrity();try db.foreignKeys()
        guard !isCancelled(),!browserRunning(first.category.browser) else {throw BrowserPrivacyError.rejected("提交前取消或浏览器重启，已回滚；备份仍可导出")}
        // The durable record remains "backedUp" until COMMIT succeeds. A crash never falsely records a clear.
        try db.exec("COMMIT");committed=true
        receipt.state = .cleared
        do {try save(receipt,to:record);return (receipt,nil)}
        catch {return (receipt,"数据库已实际清理，但收据状态更新失败；原始备份仍存在，请重新统计核对。")}

    }
    private func plan(_ category:BrowserPrivacyCategory,db:PrivacyDB) throws -> PrivacyPlan {
        var counts:[String:String]=[:],deletes:[(String,String)]=[],updates:[String]=[]
        func whole(_ table:String,required:Set<String>) throws {
            try db.require(table,required);counts[table]="SELECT COUNT(*) FROM \"\(table)\"";deletes.append((table,"DELETE FROM \"\(table)\""))
        }
        func optional(_ table:String,required:Set<String>) throws {if !(try db.columns(table)).isEmpty {try whole(table,required:required)}}
        switch category {
        case .chromeHistory:
            try optional("visit_source",required:["id"]);try optional("keyword_search_terms",required:["url_id"])
            try optional("segment_usage",required:["segment_id"]);try optional("segments",required:["id"])
            try whole("visits",required:["id","url","visit_time"]);try whole("urls",required:["id","url","visit_count"])
        case .chromeDownloads:
            try optional("downloads_url_chains",required:["id","url"]);try whole("downloads",required:["id","target_path"])
        case .chromeCookies:
            try whole("cookies",required:["host_key","name","path","encrypted_value"])
        case .firefoxCookies:
            try whole("moz_cookies",required:["host","name","path","value"])
        case .firefoxHistory,.firefoxDownloads:
            try db.require("moz_historyvisits",["id","place_id","visit_type","visit_date"])
            try db.require("moz_places",["id","visit_count","last_visit_date"])
            try db.require("moz_bookmarks",["id","fk"])
            let predicate=category == .firefoxHistory ? "visit_type<>7" : "visit_type=7"
            counts["moz_historyvisits"]="SELECT COUNT(*) FROM moz_historyvisits WHERE "+predicate
            deletes.append(("moz_historyvisits","DELETE FROM moz_historyvisits WHERE "+predicate))
            if category == .firefoxDownloads,!(try db.columns("moz_annos")).isEmpty,!(try db.columns("moz_anno_attributes")).isEmpty {
                try db.require("moz_annos",["id","anno_attribute_id"]);try db.require("moz_anno_attributes",["id","name"])
                let filter="anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name IN ('downloads/destinationFileURI','downloads/metaData'))"
                counts["moz_annos"]="SELECT COUNT(*) FROM moz_annos WHERE "+filter
                deletes.append(("moz_annos","DELETE FROM moz_annos WHERE "+filter))
            }
            updates.append("UPDATE moz_places SET visit_count=(SELECT COUNT(*) FROM moz_historyvisits v WHERE v.place_id=moz_places.id AND v.visit_type NOT IN (0,4,7,8,9)),last_visit_date=(SELECT MAX(visit_date) FROM moz_historyvisits v WHERE v.place_id=moz_places.id)")
            let cols=try db.columns("moz_places")
            if cols.contains("recalc_frecency") {updates.append("UPDATE moz_places SET recalc_frecency=1")}
            if cols.contains("recalc_alt_frecency") {updates.append("UPDATE moz_places SET recalc_alt_frecency=1")}
            if !(try db.columns("moz_origins")).isEmpty {
                let origins=try db.columns("moz_origins")
                if origins.contains("recalc_frecency") {updates.append("UPDATE moz_origins SET recalc_frecency=1")}
                if origins.contains("recalc_alt_frecency") {updates.append("UPDATE moz_origins SET recalc_alt_frecency=1")}
            }
        }
        return PrivacyPlan(category:category,counts:counts,deletes:deletes,updates:updates)
    }
    private func validatePath(_ file:URL,profileRoot:String) throws {
        guard FileSafety.contains(profileRoot,file.standardizedFileURL.path),file.standardizedFileURL.path != profileRoot,!FileSafety.hasSymlinkComponent(file),!FileSafety.isProtected(file),let i=FileSafety.identity(file),i.size>0,i.size<=1_000_000_000 else {throw BrowserPrivacyError.rejected("数据库路径、身份或1GB大小上限不满足条件")}
        for suffix in ["-wal","-shm"] {if FileSafety.hasSymlinkComponent(URL(fileURLWithPath:file.path+suffix)) {throw BrowserPrivacyError.rejected("数据库辅助文件含符号链接")}}
    }
    private func backupDirectory() throws -> URL {
        guard !FileSafety.hasSymlinkComponent(storageRoot) else {throw BrowserPrivacyError.rejected("备份目录包含符号链接")}
        try FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return storageRoot
    }
    private func requireDisk(_ source:URL,backupDirectory:URL) throws {
        let db=FileSafety.identity(source)?.size ?? 0,wal=FileSafety.identity(URL(fileURLWithPath:source.path+"-wal"))?.size ?? 0
        guard wal<=256_000_000 else {throw BrowserPrivacyError.rejected("WAL超过256MB上限，请退出浏览器后使用其自带清理")}
        let required=db*3+wal+64_000_000
        for u in [source.deletingLastPathComponent(),backupDirectory] {
            let values=try u.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
            guard let available=values.volumeAvailableCapacityForImportantUsage,available>required else {throw BrowserPrivacyError.rejected("磁盘空间不足以保留备份和事务日志")}
        }
    }
    private func onlineBackup(source:String,to destination:URL,isCancelled:@escaping @Sendable ()->Bool) throws {
        let input=try PrivacyDB(source,write:false,cancelled:isCancelled,seconds:30)
        let output=try PrivacyDB(destination.path,write:true,create:true,cancelled:isCancelled,seconds:30)
        guard let backup=sqlite3_backup_init(output.pointer,"main",input.pointer,"main") else {throw BrowserPrivacyError.rejected("无法初始化SQLite分页备份")}
        var status:Int32=SQLITE_OK
        let deadline=Date().addingTimeInterval(30)
        repeat {
            if isCancelled() || Date()>deadline {status=SQLITE_INTERRUPT;break}
            status=sqlite3_backup_step(backup,64)
            if status==SQLITE_BUSY || status==SQLITE_LOCKED {Thread.sleep(forTimeInterval:0.02)}
        } while status==SQLITE_OK || status==SQLITE_BUSY || status==SQLITE_LOCKED
        let finished=sqlite3_backup_finish(backup)
        guard status==SQLITE_DONE,finished==SQLITE_OK else {throw BrowserPrivacyError.rejected("SQLite备份未完整完成，原数据库未清理")}
        // Only the backup changes journal mode. No source WAL is removed or checkpointed explicitly.
        try output.exec("PRAGMA journal_mode=DELETE");try output.integrity()
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
    }
    private func hash(_ url:URL) throws -> String {
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()};var sha=SHA256()
        while let data=try file.read(upToCount:65_536),!data.isEmpty {sha.update(data:data)}
        return sha.finalize().map {String(format:"%02x",$0)}.joined()
    }
    private func save(_ receipt:BrowserPrivacyBackupReceipt,to url:URL) throws {
        guard !FileSafety.hasSymlinkComponent(url) else {throw BrowserPrivacyError.rejected("恢复收据路径含符号链接")}
        try JSONEncoder().encode(receipt).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
