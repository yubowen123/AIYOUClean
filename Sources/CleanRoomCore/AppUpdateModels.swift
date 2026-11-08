import Foundation

public enum AppUpdateDistribution: String, Codable, Sendable { case sparkle, appStore, unknown }
public struct AppUpdateTarget: Identifiable, Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let feedURL: URL?
    public let sparklePublicKey: String?
    public let distribution: AppUpdateDistribution
    public let identity: FileIdentity?
    public let requiresSignedFeed: Bool
    public var id: String { path }
    public init(path:String,name:String,bundleID:String,version:String,build:String,feedURL:URL?,sparklePublicKey:String? = nil,distribution:AppUpdateDistribution = .sparkle,identity:FileIdentity? = nil,requiresSignedFeed:Bool = false) {
        self.path=path; self.name=name; self.bundleID=bundleID; self.version=version; self.build=build; self.feedURL=feedURL; self.sparklePublicKey=sparklePublicKey; self.distribution=distribution; self.identity=identity; self.requiresSignedFeed=requiresSignedFeed
    }
}
public enum AppUpdateState: String, Codable, Sendable {
    case unchecked, noSource, appStore, updateAvailable, upToDate, incompatible, failed
    public var title:String {
        switch self {
        case .unchecked:return "未检查"
        case .noSource:return "没有可用更新源"
        case .appStore:return "App Store 管理"
        case .updateAvailable:return "有可用更新"
        case .upToDate:return "此更新源无较新版本"
        case .incompatible:return "发现更新，但当前系统或渠道不适用"
        case .failed:return "检查失败"
        }
    }
}
public struct AppcastRelease: Identifiable, Codable, Hashable, Sendable {
    public let version:String
    public let displayVersion:String
    public let title:String
    public let archiveURL:URL?
    public let websiteURL:URL?
    public let edSignature:String?
    public let length:Int64?
    public let minimumOS:String?
    public let maximumOS:String?
    public let hardwareRequirements:String?
    public let channel:String?
    public let isDelta:Bool
    public let isInformational:Bool
    public var id:String { version + ":" + (archiveURL?.absoluteString ?? websiteURL?.absoluteString ?? "") }
    public init(version:String,displayVersion:String? = nil,title:String = "",archiveURL:URL?,websiteURL:URL? = nil,edSignature:String? = nil,length:Int64? = nil,minimumOS:String? = nil,maximumOS:String? = nil,hardwareRequirements:String? = nil,channel:String? = nil,isDelta:Bool = false,isInformational:Bool = false) {
        self.version=version; self.displayVersion=displayVersion ?? version; self.title=title; self.archiveURL=archiveURL; self.websiteURL=websiteURL; self.edSignature=edSignature; self.length=length; self.minimumOS=minimumOS; self.maximumOS=maximumOS; self.hardwareRequirements=hardwareRequirements; self.channel=channel; self.isDelta=isDelta; self.isInformational=isInformational
    }
}
public struct AppUpdateCheck: Identifiable, Sendable {
    public let target:AppUpdateTarget
    public let state:AppUpdateState
    public let release:AppcastRelease?
    public let message:String
    public let checkedAt:Date?
    public var id:String { target.id }
    public init(target:AppUpdateTarget,state:AppUpdateState,release:AppcastRelease? = nil,message:String = "",checkedAt:Date? = nil) {
        self.target=target; self.state=state; self.release=release; self.message=message; self.checkedAt=checkedAt
    }
}
public struct DownloadedAppUpdate: Sendable {
    public let check:AppUpdateCheck
    public let archiveURL:URL
    public let sha256:String
    public let archiveIdentity:FileIdentity
    public let signatureVerified:Bool
    public init(check:AppUpdateCheck,archiveURL:URL,sha256:String,archiveIdentity:FileIdentity,signatureVerified:Bool) {
        self.check=check; self.archiveURL=archiveURL; self.sha256=sha256; self.archiveIdentity=archiveIdentity; self.signatureVerified=signatureVerified
    }
}
public struct PreparedAppUpdate: Sendable {
    public let downloaded:DownloadedAppUpdate
    public let applicationURL:URL
    public let applicationIdentity:FileIdentity
    public let originalTeamID:String
    public let candidateTeamID:String
    public let candidateBuild:String
    public let workingDirectory:URL
}
public struct AppUpdateInstallReceipt: Codable, Sendable {
    public let date:Date
    public let bundleID:String
    public let installedPath:String
    public let backupPath:String
    public let previousBuild:String
    public let installedBuild:String
}
public enum AppUpdateError: LocalizedError {
    case invalid(String)
    public var errorDescription:String? { if case .invalid(let s)=self { return s }; return nil }
}

/// Conservative machine-readable build comparator. Unknown build formats are not silently ordered.
public enum AppUpdateVersion {
    public static func compare(_ a:String,_ b:String) -> ComparisonResult? {
        guard let left = components(a), let right = components(b) else { return nil }
        for i in 0..<max(left.count,right.count) {
            let l = i < left.count ? left[i] : "0", r = i < right.count ? right[i] : "0"
            if l.count != r.count { return l.count > r.count ? .orderedDescending : .orderedAscending }
            if l != r { return l > r ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
    private static func components(_ s:String) -> [String]? {
        guard !s.isEmpty, s.count < 200, s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"0123456789.").contains($0) }) else { return nil }
        let parts=s.split(separator:".",omittingEmptySubsequences:false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.map { p in let v=p.drop(while:{$0=="0"}); return v.isEmpty ? "0" : String(v) }
    }
}
