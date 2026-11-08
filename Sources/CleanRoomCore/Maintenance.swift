import Foundation
import AppKit

public enum MaintenanceTaskKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case flushDNS, reindexSpotlight, thinSnapshots, freeMemory, verifyVolume, periodic
    public var id:String { rawValue }
    public var title:String {
        switch self {case .flushDNS:return "刷新 DNS 缓存";case .reindexSpotlight:return "重建 Spotlight 索引";case .thinSnapshots:return "缩减本地 Time Machine 快照";case .freeMemory:return "请求系统回收内存缓存";case .verifyVolume:return "验证启动卷";case .periodic:return "运行系统维护脚本"}
    }
    public var detail:String {
        switch self {
        case .flushDNS:return "刷新解析缓存并通知 mDNSResponder；不修改网络设置。"
        case .reindexSpotlight:return "提交启动卷索引重建请求；重建在系统后台继续，不把请求成功当作重建完成。"
        case .thinSnapshots:return "请求系统最多回收约 5 GB 本地快照；这些历史快照可能无法恢复，原备份磁盘不受影响。"
        case .freeMemory:return "调用系统 purge 请求释放可回收缓存；不保证性能提升，部分进程可能需要重新载入内容。"
        case .verifyVolume:return "只验证卷文件系统，不执行磁盘修复。"
        case .periodic:return "仅当本机仍提供 periodic 时运行 daily/weekly/monthly 脚本。"
        }
    }
}
public struct MaintenancePlan: Sendable {
    public let task:MaintenanceTaskKind
    public let commands:[(String,[String])]
    public let administrator:Bool
    public let supported:Bool
    public let reason:String?
    public var preview:String { commands.map { ShellEscaping.command($0.0,$0.1) }.joined(separator:"\n") }
}
public struct MaintenanceResult: Codable, Sendable {
    public let task:MaintenanceTaskKind
    public let startedAt:Date
    public let finishedAt:Date
    public let success:Bool
    public let output:String
    public let exitCode:Int32
    public let note:String
}
public enum ShellEscaping {
    public static func quote(_ arg:String)->String { "'" + arg.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    public static func command(_ executable:String,_ arguments:[String])->String { ([executable]+arguments).map(quote).joined(separator:" ") }
    public static func appleScriptString(_ string:String)->String { "\""+string.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r")+"\"" }
}
public enum MaintenanceService {
    public static func plan(_ kind:MaintenanceTaskKind)->MaintenancePlan {
        let commands:[(String,[String])];let admin:Bool
        switch kind {
        case .flushDNS:commands=[("/usr/bin/dscacheutil",["-flushcache"]),("/usr/bin/killall",["-HUP","mDNSResponder"])];admin=true
        case .reindexSpotlight:commands=[("/usr/bin/mdutil",["-E","/"])];admin=true
        case .thinSnapshots:commands=[("/usr/bin/tmutil",["thinlocalsnapshots","/","5000000000","2"])];admin=true
        case .freeMemory:commands=[("/usr/sbin/purge",[])];admin=true
        case .verifyVolume:commands=[("/usr/sbin/diskutil",["verifyVolume","/"])];admin=false
        case .periodic:commands=[("/usr/sbin/periodic",["daily","weekly","monthly"])];admin=true
        }
        let available=commands.allSatisfy { FileManager.default.isExecutableFile(atPath:$0.0) }
        return MaintenancePlan(task:kind,commands:commands,administrator:admin,supported:available,reason:available ? nil : "当前系统未提供所需命令；不适用的旧维护项目不会被模拟执行。")
    }
    /// Invoked only after a user reviews and confirms the fixed command plan in the app.
    public static func execute(_ kind:MaintenanceTaskKind, confirmed:Bool)->MaintenanceResult {
        let start=Date();let p=plan(kind)
        guard let permit = WorkBudget.tryAcquire("系统维护：" + kind.title) else { return MaintenanceResult(task:kind,startedAt:start,finishedAt:Date(),success:false,output:"另一个重操作正在运行",exitCode:-1,note:"未执行") }
        defer { permit.release() }
        guard confirmed,p.supported else { return MaintenanceResult(task:kind,startedAt:start,finishedAt:Date(),success:false,output:p.reason ?? "用户未确认",exitCode:-1,note:"未执行") }
        let result:CommandResult
        if p.administrator {
            // Inputs are exclusively enum-derived commands; no user paths or arbitrary command text.
            let shell=p.commands.map { ShellEscaping.command($0.0,$0.1) }.joined(separator:" && ")
            let script="do shell script " + ShellEscaping.appleScriptString(shell) + " with administrator privileges"
            result=CommandRunner.run("/usr/bin/osascript",["-e",script],timeout:300)
        } else { result=CommandRunner.run(p.commands[0].0,p.commands[0].1,timeout:180) }
        let note=kind == .reindexSpotlight && result.code == 0 ? "索引重建请求已提交；后台完成状态需后续读取。" : "仅按退出码报告命令执行结果；不据此承诺性能改善或释放体积。"
        return MaintenanceResult(task:kind,startedAt:start,finishedAt:Date(),success:result.code == 0,output:result.output,exitCode:result.code,note:note)
    }
    public static func snapshots()->CommandResult {CommandRunner.run("/usr/bin/tmutil",["listlocalsnapshots","/"],timeout:15)}
    public static func spotlightStatus()->CommandResult {CommandRunner.run("/usr/bin/mdutil",["-s","/"],timeout:15)}
}

public struct StartupEntry:Identifiable,Sendable {
    public let id:String
    public let label:String
    public let path:String
    public let program:String
    public let userOwned:Bool
    public let identity:FileIdentity?
    public let loaded:Bool
    public let state:String
}
public enum StartupManager {
    public static func list(home:URL=FileManager.default.homeDirectoryForCurrentUser)->[StartupEntry] {
        let fm=FileManager.default
        let dirs=[home.appendingPathComponent("Library/LaunchAgents"),URL(fileURLWithPath:"/Library/LaunchAgents"),URL(fileURLWithPath:"/Library/LaunchDaemons")]
        var out:[StartupEntry]=[]
        for dir in dirs {
            for url in (try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? [] where url.pathExtension == "plist" {
                guard !FileSafety.hasSymlinkComponent(url),let data=try? Data(contentsOf:url),let plist=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],let label=plist["Label"] as? String,label.range(of:#"^[A-Za-z0-9._-]+$"#,options:.regularExpression) != nil else {continue}
                let own=FileSafety.contains(home.appendingPathComponent("Library/LaunchAgents").path,url.path)
                let domain=(url.path.contains("LaunchDaemons") ? "system/" : "gui/\(getuid())/")+label
                let status=CommandRunner.run("/bin/launchctl",["print",domain],timeout:3)
                let args=plist["ProgramArguments"] as? [String] ?? []
                out.append(StartupEntry(id:url.path,label:label,path:url.path,program:plist["Program"] as? String ?? args.first ?? "未知",userOwned:own,identity:FileSafety.identity(url),loaded:status.code == 0,state:status.code == 0 ? "已加载" : "未加载或无读取权限"))
            }
        }
        return out.sorted {$0.label < $1.label}
    }
    public static func setLoaded(_ loaded:Bool,entry:StartupEntry,confirmed:Bool)->CommandResult {
        let u=URL(fileURLWithPath:entry.path)
        let home=FileManager.default.homeDirectoryForCurrentUser
        guard confirmed,entry.userOwned,FileSafety.contains(home.appendingPathComponent("Library/LaunchAgents").path,u.path),!entry.label.hasPrefix("com.apple."),!FileSafety.hasSymlinkComponent(u),FileSafety.identity(u) == entry.identity else {return CommandResult(code:-1,output:"仅支持已确认且身份未变的当前用户 LaunchAgent；系统与第三方受管登录项请使用系统设置。")}
        let domain="gui/\(getuid())"
        let result=CommandRunner.run("/bin/launchctl",loaded ? ["bootstrap",domain,u.path] : ["bootout",domain+"/"+entry.label],timeout:20)
        guard result.code == 0 else{return result}
        let verify=CommandRunner.run("/bin/launchctl",["print",domain+"/"+entry.label],timeout:5)
        guard (verify.code == 0) == loaded else {return CommandResult(code:-1,output:"命令返回成功，但加载状态回读不一致，请核对系统设置。")}
        return CommandResult(code:0,output:loaded ? "已加载；本工具未修改开机启动策略。" : "当前会话已卸载；配置文件保留，下次登录是否启动由系统配置决定。")
    }
}
