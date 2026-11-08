import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum AppUpdateURLPolicy {
    public static func validate(_ url:URL) throws {
        guard url.scheme?.lowercased()=="https", let host=url.host, !host.isEmpty, url.user==nil, url.password==nil else { throw AppUpdateError.invalid("更新源和下载链接必须为没有内嵌凭证的 HTTPS 地址") }
    }
}
public enum AppUpdateAppcast {
    public static func parse(_ data:Data) throws -> [AppcastRelease] {
        guard data.count <= 4_194_304 else { throw AppUpdateError.invalid("更新源超过4MB上限") }
        let upper=String(decoding:data,as:UTF8.self).uppercased()
        guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else { throw AppUpdateError.invalid("拒绝包含外部实体声明的更新源") }
        let handler=AppcastXMLDelegate(); let p=XMLParser(data:data)
        p.shouldResolveExternalEntities=false; p.delegate=handler
        guard p.parse(), handler.error==nil else { throw AppUpdateError.invalid("更新源XML损坏或不受支持") }
        return handler.releases
    }
    public static func select(_ releases:[AppcastRelease],target:AppUpdateTarget,osVersion:String,architecture:String,allowedChannels:Set<String> = []) throws -> (AppcastRelease?,Bool) {
        guard AppUpdateVersion.compare(target.build,target.build) != nil else { throw AppUpdateError.invalid("应用构建号不是受支持的数字版本；请使用应用自己的更新器") }
        var newer:[AppcastRelease]=[]; var compatible:[AppcastRelease]=[]
        for r in releases {
            guard let order=AppUpdateVersion.compare(r.version,target.build) else { throw AppUpdateError.invalid("更新源含不受支持的构建号；请使用原应用更新器") }
            guard order == .orderedDescending else { continue }
            newer.append(r)
            if let c=r.channel, !c.isEmpty, !allowedChannels.contains(c) { continue }
            if let min=r.minimumOS { guard let c=AppUpdateVersion.compare(osVersion,min), c != .orderedAscending else { continue } }
            if let max=r.maximumOS { guard let c=AppUpdateVersion.compare(osVersion,max), c != .orderedDescending else { continue } }
            if let h=r.hardwareRequirements, !h.isEmpty {
                let requirements=Set(h.lowercased().split(whereSeparator:{$0=="," || $0==" "}).map(String.init))
                guard requirements == ["arm64"], architecture == "arm64" else { continue }
            }
            if r.isDelta { continue }
            if let archive=r.archiveURL { try AppUpdateURLPolicy.validate(archive) }
            else if let website=r.websiteURL { try AppUpdateURLPolicy.validate(website) }
            else { continue }
            compatible.append(r)
        }
        compatible.sort { AppUpdateVersion.compare($0.version,$1.version) == .orderedDescending }
        return (compatible.first,!newer.isEmpty)
    }
}
private final class AppcastXMLDelegate:NSObject,XMLParserDelegate {
    var releases:[AppcastRelease]=[]
    var error:Error?
    private var fields:[String:String]=[:]
    private var enclosures:[[String:String]]=[]
    private var stack:[String]=[]
    private var text=""
    private var inItem=false
    private var informational=false
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]) {
        stack.append(name); text=""
        if name=="item" { inItem=true; fields=[:]; enclosures=[]; informational=false }
        if inItem && name=="enclosure" { enclosures.append(attributes) }
        if inItem && name=="sparkle:informationalUpdate" { informational=true }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if text.utf8.count < 32_768 { text += string } }
    func parser(_ parser:XMLParser,foundCDATA CDATABlock:Data) { if text.utf8.count + CDATABlock.count < 32_768 { text += String(decoding:CDATABlock,as:UTF8.self) } }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName qName:String?) {
        defer { _=stack.popLast(); text="" }
        if inItem, stack.count>=2, stack[stack.count-2]=="item" { fields[name]=text.trimmingCharacters(in:.whitespacesAndNewlines) }
        guard name=="item", inItem else { return }; inItem=false
        if enclosures.isEmpty { enclosures=[[:]] }
        for a in enclosures {
            if let os=a["sparkle:os"], os != "macos" { continue }
            let version=fields["sparkle:version"] ?? a["sparkle:version"] ?? ""
            guard !version.isEmpty else { continue }
            let release=AppcastRelease(version:version,displayVersion:fields["sparkle:shortVersionString"] ?? a["sparkle:shortVersionString"],title:fields["title"] ?? "",archiveURL:a["url"].flatMap(URL.init(string:)),websiteURL:fields["link"].flatMap(URL.init(string:)),edSignature:a["sparkle:edSignature"],length:a["length"].flatMap(Int64.init),minimumOS:fields["sparkle:minimumSystemVersion"],maximumOS:fields["sparkle:maximumSystemVersion"],hardwareRequirements:fields["sparkle:hardwareRequirements"],channel:fields["sparkle:channel"],isDelta:a["sparkle:deltaFrom"] != nil,isInformational:informational)
            releases.append(release)
        }
    }
    func parser(_ parser:XMLParser,parseErrorOccurred parseError:Error) { error=parseError }
}
