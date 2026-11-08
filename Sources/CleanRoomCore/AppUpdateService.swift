import Foundation
import CryptoKit
import AppKit
import Darwin

public final class AppUpdateService:@unchecked Sendable {
    private let transport:any AppUpdateTransport
    public let storageRoot:URL
    public init(transport:any AppUpdateTransport = AppUpdateHTTPSClient(),storageRoot:URL? = nil) {
        self.transport=transport
        self.storageRoot=storageRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AIYOUClean/Updates")
    }
    public static var currentOS:String {
        let v=ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    public static var currentArchitecture:String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    public func inventory(roots:[URL] = [URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> [AppUpdateTarget] {
        let fm=FileManager.default; var apps:[AppUpdateTarget]=[]; var seen=Set<String>()
        func append(_ u:URL) {
            guard !FileSafety.hasSymlinkComponent(u),seen.insert(u.standardizedFileURL.path).inserted,let info=Self.info(u),let bundle=info["CFBundleIdentifier"] as? String else { return }
            let isStore=fm.fileExists(atPath:u.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            let feed=(info["SUFeedURL"] as? String).flatMap(URL.init(string:))
            apps.append(AppUpdateTarget(path:u.path,name:info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? u.deletingPathExtension().lastPathComponent,bundleID:bundle,version:info["CFBundleShortVersionString"] as? String ?? "未知",build:info["CFBundleVersion"] as? String ?? "",feedURL:feed,sparklePublicKey:info["SUPublicEDKey"] as? String,distribution:isStore ? .appStore : (feed != nil ? .sparkle : .unknown),identity:FileSafety.identity(u),requiresSignedFeed:info["SURequireSignedFeed"] as? Bool ?? false))
        }
        for root in roots {
            if root.pathExtension.lowercased()=="app" { append(root); continue }
            guard !FileSafety.hasSymlinkComponent(root),let e=fm.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            var visited=0
            for case let u as URL in e {
                visited+=1; if visited>20_000 { break }
                if FileSafety.isSymbolicLink(u) { e.skipDescendants(); continue }
                if u.pathExtension.lowercased()=="app" { append(u); e.skipDescendants() }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func check(_ target:AppUpdateTarget,allowedChannels:Set<String> = [],osVersion:String = AppUpdateService.currentOS,architecture:String = AppUpdateService.currentArchitecture) async -> AppUpdateCheck {
        let date=Date()
        if target.distribution == .appStore { return .init(target:target,state:.appStore,message:"由 App Store 管理；此页未查询商店版本，不能判断是否最新。",checkedAt:date) }
        if target.requiresSignedFeed { return .init(target:target,state:.failed,message:"此应用要求 Sparkle 完整签名源验证；本工具未实现该源签名协议，请使用原应用更新器。",checkedAt:date) }
        guard let feed=target.feedURL else { return .init(target:target,state:.noSource,message:"应用未声明 Sparkle SUFeedURL；请使用其自带更新器或官网。",checkedAt:date) }
        do {
            try AppUpdateURLPolicy.validate(feed)
            let data=try await transport.fetch(feed,maximumBytes:4_194_304)
            try Task.checkCancellation()
            let releases=try AppUpdateAppcast.parse(data)
            guard !releases.isEmpty else { throw AppUpdateError.invalid("更新源没有可解析的 macOS 发布项；未判定最新") }
            let (selected,newer)=try AppUpdateAppcast.select(releases,target:target,osVersion:osVersion,architecture:architecture,allowedChannels:allowedChannels)
            if let selected { return .init(target:target,state:.updateAvailable,release:selected,message:selected.isInformational ? "此发布项要求使用官网/原应用更新流程。" : "检测到该更新源上的较新兼容版本；尚未下载或安装。",checkedAt:date) }
            return .init(target:target,state:newer ? .incompatible : .upToDate,message:newer ? "存在较新构建，但受系统版本、硬件、频道或增量包限制；未选中可安装发布。" : "在此源已解析的数字构建版本中，没有较新项。没有更新源的应用不在此结论内。",checkedAt:date)
        } catch { return .init(target:target,state:.failed,message:error is CancellationError ? "检查已取消；未判定最新。" : error.localizedDescription,checkedAt:date) }
    }
    public static func verifyArchive(_ data:Data,publicKey:String,signature:String) throws {
        guard let keyData=Data(base64Encoded:publicKey.trimmingCharacters(in:.whitespacesAndNewlines)),let signatureData=Data(base64Encoded:signature),let key=try? Curve25519.Signing.PublicKey(rawRepresentation:keyData),key.isValidSignature(signatureData,for:data) else { throw AppUpdateError.invalid("更新包 Ed25519 签名验证失败") }
    }
    public func download(_ check:AppUpdateCheck) async throws -> DownloadedAppUpdate {
        guard check.state == .updateAvailable,let release=check.release,!release.isInformational,let source=release.archiveURL else { throw AppUpdateError.invalid("该发布项需要使用原应用或官网更新，不能在此下载完整更新包") }
        try AppUpdateURLPolicy.validate(source)
        let ext=source.pathExtension.lowercased()
        guard ["zip","dmg"].contains(ext) else { throw AppUpdateError.invalid("此独立更新器仅支持 ZIP / DMG 完整包；请使用原应用更新器") }
        let maxBytes:Int64=256_000_000
        if let length=release.length { guard length>0,length<=maxBytes else { throw AppUpdateError.invalid("更新包声明体积无效或超过256MB上限") } }
        let folder=try directory("Downloads")
        let destination=folder.appendingPathComponent(UUID().uuidString+"."+ext)
        do {
            try await transport.download(source,to:destination,maximumBytes:maxBytes)
            guard let i=FileSafety.identity(destination),i.size>0,i.size<=maxBytes else { throw AppUpdateError.invalid("下载文件大小无效") }
            if let length=release.length,length != i.size { throw AppUpdateError.invalid("下载大小与更新源声明不符") }
            let data=try Data(contentsOf:destination,options:.alwaysMapped)
            var verified=false
            if let key=check.target.sparklePublicKey,let signature=release.edSignature {
                try Self.verifyArchive(data,publicKey:key,signature:signature); verified=true
            }
            // Preserve the normal Gatekeeper assessment path for Internet downloads.
            let quarantine="0083;"+String(Int(Date().timeIntervalSince1970),radix:16)+";AIYOUClean;"+UUID().uuidString
            let result=quarantine.withCString { value in setxattr(destination.path,"com.apple.quarantine",value,strlen(value),0,0) }
            guard result==0 else { throw AppUpdateError.invalid("无法为下载保留系统隔离标记，已停止") }
            return DownloadedAppUpdate(check:check,archiveURL:destination,sha256:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),archiveIdentity:i,signatureVerified:verified)
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
    /// Verifies the signed archive before extraction; no account/system protection changes.
    public func prepare(_ downloaded:DownloadedAppUpdate) throws -> PreparedAppUpdate {
        guard let permit=WorkBudget.tryAcquire("准备应用更新") else { throw AppUpdateError.invalid("另一项扫描、检测或维护任务正在运行，请待其结束后再准备应用更新") }
        defer { permit.release() }
        guard downloaded.signatureVerified,FileSafety.identity(downloaded.archiveURL)==downloaded.archiveIdentity,!FileSafety.hasSymlinkComponent(downloaded.archiveURL),let key=downloaded.check.target.sparklePublicKey,let signature=downloaded.check.release?.edSignature else { throw AppUpdateError.invalid("缺少有效 Sparkle Ed25519 签名或文件已变化；请改用原应用的更新器") }
        let data=try Data(contentsOf:downloaded.archiveURL,options:.alwaysMapped)
        try Self.verifyArchive(data,publicKey:key,signature:signature)
        let workspace=try directory("Prepared").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var hasActiveMount=false
        do {
            let extracted:URL
            if downloaded.archiveURL.pathExtension.lowercased()=="zip" {
                let entries=try AppUpdateZIP.entries(data)
                let expanded=entries.reduce(Int64(0)) { $0 + Int64($1.uncompressedBytes) }
                let disk=try workspace.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
                guard let available=disk.volumeAvailableCapacityForImportantUsage,available>expanded+max(64_000_000,expanded/4) else { throw AppUpdateError.invalid("可用磁盘不足以安全解压；未提取") }
                for entry in entries where entry.isSymlink {
                    let link=CommandRunner.run("/usr/bin/unzip",["-p",downloaded.archiveURL.path,entry.path],timeout:8)
                    guard link.code==0,entry.uncompressedBytes<=4096,AppUpdateZIP.validateSymlinkTarget(link.output,entryPath:entry.path) else { throw AppUpdateError.invalid("ZIP符号链接目标不安全") }
                }
                extracted=workspace.appendingPathComponent("Extracted")
                try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:false)
                try extractZIP(downloaded.archiveURL,to:extracted)
            } else {
                let mount=workspace.appendingPathComponent("Mounted")
                try FileManager.default.createDirectory(at:mount,withIntermediateDirectories:false)
                let mounted=CommandRunner.run("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,downloaded.archiveURL.path],timeout:90)
                hasActiveMount=mounted.code==0 || (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[]) ?? []).contains(where:{$0.standardizedFileURL.path==mount.standardizedFileURL.path})
                guard mounted.code==0 else { throw AppUpdateError.invalid("DMG只读挂载失败") }
                do {
                    let source=try findApplication(in:mount,bundleID:downloaded.check.target.bundleID)
                    let candidateBytes=try validateBundleSymlinks(source)
                    try requireSpace(workspace,bytes:candidateBytes)
                    extracted=workspace.appendingPathComponent("Extracted")
                    try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:false)
                    try FileManager.default.copyItem(at:source,to:extracted.appendingPathComponent(source.lastPathComponent))
                } catch {
                    let detached=CommandRunner.run("/usr/bin/hdiutil",["detach",mount.path],timeout:30)
                    hasActiveMount=detached.code != 0; throw error
                }
                let detached=CommandRunner.run("/usr/bin/hdiutil",["detach",mount.path],timeout:30)
                guard detached.code==0 else { throw AppUpdateError.invalid("DMG已复制但只读卷未能卸载，停止准备") }
                hasActiveMount=false
            }
            let application=try findApplication(in:extracted,bundleID:downloaded.check.target.bundleID)
            try validateBundleSymlinks(application)
            let info=try requireCandidate(application,target:downloaded.check.target,expectedBuild:downloaded.check.release?.version)
            let originalTeam=try Self.teamID(URL(fileURLWithPath:downloaded.check.target.path))
            let team=try Self.teamID(application)
            guard originalTeam==team else { throw AppUpdateError.invalid("更新包开发者 TeamIdentifier 与原应用不一致") }
            guard let i=FileSafety.identity(application),let build=info["CFBundleVersion"] as? String else { throw AppUpdateError.invalid("更新应用信息不完整") }
            return PreparedAppUpdate(downloaded:downloaded,applicationURL:application,applicationIdentity:i,originalTeamID:originalTeam,candidateTeamID:team,candidateBuild:build,workingDirectory:workspace)
        } catch {
            if hasActiveMount { throw AppUpdateError.invalid(error.localizedDescription+"\n只读挂载卷保留在："+workspace.appendingPathComponent("Mounted").path+"；请在 Finder 弹出后移除该缓存目录。") }
            try? FileManager.default.removeItem(at:workspace); throw error
        }
    }
    public func install(_ prepared:PreparedAppUpdate,confirmed:Bool) throws -> AppUpdateInstallReceipt {
        guard let permit=WorkBudget.tryAcquire("安装应用更新") else { throw AppUpdateError.invalid("另一项扫描、检测或维护任务正在运行，请待其结束后再安装应用更新") }
        defer { permit.release() }
        guard confirmed else { throw AppUpdateError.invalid("尚未确认安装") }
        let fm=FileManager.default, target=prepared.downloaded.check.target
        let original=URL(fileURLWithPath:target.path).standardizedFileURL
        guard !target.bundleID.hasPrefix("com.apple."),target.bundleID != Bundle.main.bundleIdentifier,!FileSafety.hasSymlinkComponent(original),!FileSafety.isProtected(original),original.pathExtension=="app",FileSafety.identity(original)==target.identity,FileSafety.identity(prepared.applicationURL)==prepared.applicationIdentity else { throw AppUpdateError.invalid("原应用/候选已变化、路径受保护或不能更新当前应用；请重新检查") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier:target.bundleID).isEmpty else { throw AppUpdateError.invalid("应用正在运行，请先退出后再安装") }
        guard try Self.teamID(original)==prepared.originalTeamID,try Self.teamID(prepared.applicationURL)==prepared.originalTeamID else { throw AppUpdateError.invalid("开发者签名已变化") }
        _=try requireCandidate(prepared.applicationURL,target:target,expectedBuild:prepared.candidateBuild)
        let parent=original.deletingLastPathComponent()
        let candidateBytes=try validateBundleSymlinks(prepared.applicationURL)
        try requireSpace(parent,bytes:candidateBytes)
        let staging=parent.appendingPathComponent(".AIYOUClean-update-"+UUID().uuidString+".app")
        guard fm.isWritableFile(atPath:parent.path),!fm.fileExists(atPath:staging.path) else { throw AppUpdateError.invalid("没有此应用目录的写入权限；请使用原应用更新器") }
        var swapped=false
        do {
            try fm.copyItem(at:prepared.applicationURL,to:staging)
            try validateBundleSymlinks(staging)
            guard try Self.teamID(staging)==prepared.originalTeamID else { throw AppUpdateError.invalid("暂存副本签名验证失败") }
            _=try requireCandidate(staging,target:target,expectedBuild:prepared.candidateBuild)
            let assess=CommandRunner.run("/usr/sbin/spctl",["--assess","--type","execute",staging.path],timeout:45)
            guard assess.code==0 else { throw AppUpdateError.invalid("Gatekeeper 未接受该应用，未安装。请使用原应用或官网更新流程") }
            guard FileSafety.identity(original)==target.identity,NSRunningApplication.runningApplications(withBundleIdentifier:target.bundleID).isEmpty else { throw AppUpdateError.invalid("安装前原应用变化或重新启动，已停止") }
            guard renameatx_np(AT_FDCWD,original.path,AT_FDCWD,staging.path,UInt32(RENAME_SWAP))==0 else { throw AppUpdateError.invalid("系统原子交换失败："+String(cString:strerror(errno))) }
            swapped=true
            do {
                guard try Self.teamID(original)==prepared.originalTeamID else { throw AppUpdateError.invalid("安装后签名回读失败") }
                _=try requireCandidate(original,target:target,expectedBuild:prepared.candidateBuild)
                let receipt=AppUpdateInstallReceipt(date:Date(),bundleID:target.bundleID,installedPath:original.path,backupPath:staging.path,previousBuild:target.build,installedBuild:prepared.candidateBuild)
                let records=try directory("Receipts")
                try JSONEncoder().encode(receipt).write(to:records.appendingPathComponent(UUID().uuidString+".json"),options:.atomic)
                return receipt
            } catch {
                guard renameatx_np(AT_FDCWD,original.path,AT_FDCWD,staging.path,UInt32(RENAME_SWAP))==0 else { throw AppUpdateError.invalid("安装后校验失败且交换回滚失败；旧版本保留在 "+staging.path) }
                swapped=false; throw error
            }
        } catch {
            if !swapped { try? fm.removeItem(at:staging) }
            throw error
        }
    }
    public func checkAll(_ targets:[AppUpdateTarget],allowedChannels:Set<String> = [],concurrency:Int = 2,progress:@escaping @Sendable (AppUpdateCheck)->Void = {_ in}) async -> [AppUpdateCheck] {
        let limit=max(1,min(2,concurrency))
        return await withTaskGroup(of:AppUpdateCheck.self) { group in
            var iterator=targets.makeIterator(); var output:[AppUpdateCheck]=[]
            for _ in 0..<limit { if let target=iterator.next() { group.addTask { await self.check(target,allowedChannels:allowedChannels) } } }
            while let result=await group.next() {
                output.append(result); progress(result)
                if !Task.isCancelled,let target=iterator.next() { group.addTask { await self.check(target,allowedChannels:allowedChannels) } }
            }
            return output
        }
    }
    public func checkSystemUpdates() -> CommandResult { CommandRunner.run("/usr/sbin/softwareupdate",["--list"],timeout:180) }
    private func directory(_ name:String) throws -> URL {
        let u=storageRoot.appendingPathComponent(name)
        guard !FileSafety.hasSymlinkComponent(u) else { throw AppUpdateError.invalid("更新缓存路径含符号链接") }
        try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return u
    }
    private static func info(_ u:URL) -> [String:Any]? {
        guard let data=try? Data(contentsOf:u.appendingPathComponent("Contents/Info.plist")),let p=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return nil }; return p
    }
    private func requireCandidate(_ app:URL,target:AppUpdateTarget,expectedBuild:String?) throws -> [String:Any] {
        guard let info=Self.info(app),info["CFBundleIdentifier"] as? String==target.bundleID,let build=info["CFBundleVersion"] as? String,AppUpdateVersion.compare(build,target.build) == .orderedDescending else { throw AppUpdateError.invalid("候选应用 bundle ID 不匹配、构建号不受支持或不是升级") }
        if let expectedBuild,AppUpdateVersion.compare(build,expectedBuild) != .orderedSame { throw AppUpdateError.invalid("包内构建号与发布项不一致") }
        if let minimum=info["LSMinimumSystemVersion"] as? String {
            guard let order=AppUpdateVersion.compare(Self.currentOS,minimum),order != .orderedAscending else { throw AppUpdateError.invalid("候选应用最低系统版本不兼容或无法解析") }
        }
        guard let executable=info["CFBundleExecutable"] as? String,!executable.isEmpty,executable==URL(fileURLWithPath:executable).lastPathComponent else { throw AppUpdateError.invalid("候选应用可执行文件路径无效") }
        let architectures=CommandRunner.run("/usr/bin/lipo",["-archs",app.appendingPathComponent("Contents/MacOS/"+executable).path],timeout:10)
        guard architectures.code==0,architectures.output.split(whereSeparator:{$0.isWhitespace}).contains(Substring(Self.currentArchitecture)) else { throw AppUpdateError.invalid("候选应用架构不包含当前 Mac 原生架构") }
        return info
    }
    private static func teamID(_ app:URL) throws -> String {
        let verified=CommandRunner.run("/usr/bin/codesign",["--verify","--deep","--strict",app.path],timeout:60)
        guard verified.code==0 else { throw AppUpdateError.invalid("应用完整代码签名验证失败") }
        let description=CommandRunner.run("/usr/bin/codesign",["-dv","--verbose=4",app.path],timeout:10)
        guard description.code==0,let line=description.output.split(separator:"\n").first(where:{$0.hasPrefix("TeamIdentifier=")}) else { throw AppUpdateError.invalid("无法读取应用开发者签名") }
        let team=String(line.dropFirst("TeamIdentifier=".count))
        guard team.count==10,team.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else { throw AppUpdateError.invalid("原应用或候选没有可验证的开发者 TeamIdentifier；不自动替换") }
        return team
    }
    private func findApplication(in root:URL,bundleID:String) throws -> URL {
        let matches=inventory(roots:[root]).filter {$0.bundleID==bundleID}
        guard matches.count==1 else { throw AppUpdateError.invalid("更新包必须包含唯一匹配 bundle ID 的应用") }
        return URL(fileURLWithPath:matches[0].path)
    }
    private func extractZIP(_ archive:URL,to destination:URL) throws {
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-x","-k",archive.path,destination.path]
        process.standardInput=FileHandle.nullDevice; process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        try process.run()
        let deadline=Date().addingTimeInterval(180)
        var failure:Error?
        var nextInspection=Date()
        while process.isRunning {
            if Date()>deadline { failure=AppUpdateError.invalid("ZIP提取超时"); break }
            if Date()>=nextInspection {
                do { _=try validateBundleSymlinks(destination) } catch { failure=error; break }
                nextInspection=Date().addingTimeInterval(0.5)
            }
            Thread.sleep(forTimeInterval:0.05)
        }
        if failure != nil && process.isRunning {
            process.terminate()
            let grace=Date().addingTimeInterval(1)
            while process.isRunning && Date()<grace { Thread.sleep(forTimeInterval:0.02) }
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
        }
        process.waitUntilExit()
        if let failure { throw failure }
        guard process.terminationStatus==0 else { throw AppUpdateError.invalid("ZIP提取失败") }
        _=try validateBundleSymlinks(destination)
    }
    private func requireSpace(_ directory:URL,bytes:Int64) throws {
        let values=try directory.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        guard let available=values.volumeAvailableCapacityForImportantUsage,available>bytes+max(64_000_000,bytes/4) else { throw AppUpdateError.invalid("可用磁盘不足以暂存更新，未复制") }
    }
    @discardableResult private func validateBundleSymlinks(_ root:URL) throws -> Int64 {
        let canonical=root.resolvingSymlinksInPath().standardizedFileURL.path
        let depth=root.pathComponents.count
        var traversalError=false
        guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey],options:[],errorHandler:{_,_ in traversalError=true;return false}) else { throw AppUpdateError.invalid("无法核验应用内部路径") }
        var count=0,bytes:Int64=0
        for case let u as URL in e {
            count+=1
            guard count<=20_000,u.pathComponents.count-depth<=40 else { throw AppUpdateError.invalid("更新应用项目数或路径深度超过上限") }
            if FileSafety.isSymbolicLink(u) {
                guard FileSafety.contains(canonical,u.resolvingSymlinksInPath().standardizedFileURL.path) else { throw AppUpdateError.invalid("应用包含指向包外的符号链接") }
                e.skipDescendants()
            } else {
                let values=try u.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                if values.isRegularFile==true { bytes+=Int64(values.fileSize ?? 0) }
                guard bytes<=2_000_000_000 else { throw AppUpdateError.invalid("更新应用展开体积超过2GB上限") }
            }
        }
        guard !traversalError else { throw AppUpdateError.invalid("更新应用目录未能完整核验") }
        return bytes
    }
}
