import Foundation

public struct AppUpdateZIPEntry:Sendable {
    public let path:String
    public let isSymlink:Bool
    public let uncompressedBytes:UInt32
}
/// Inspect the central directory before ditto; ZIP64, encryption and special files fail closed.
public enum AppUpdateZIP {
    public static func entries(_ data:Data,maximumExpandedBytes:UInt64=2_000_000_000) throws -> [AppUpdateZIPEntry] {
        func fail(_ text:String) -> AppUpdateError { .invalid(text) }
        func u16(_ p:Int) throws -> UInt16 {
            guard p>=0,p+2<=data.count else { throw fail("ZIP目录越界") }; return UInt16(data[p]) | UInt16(data[p+1])<<8
        }
        func u32(_ p:Int) throws -> UInt32 { UInt32(try u16(p)) | UInt32(try u16(p+2))<<16 }
        func safeExtras(_ start:Int,_ length:Int) throws -> Bool {
            var cursor=start; let end=start+length
            while cursor<end {
                guard cursor+4<=end else { return false }
                let id=try u16(cursor), bytes=Int(try u16(cursor+2))
                guard [UInt16(0x5455),0x7875,0x000a].contains(id),cursor+4+bytes<=end else { return false }
                cursor+=4+bytes
            }
            return cursor==end
        }
        guard data.count>=22 else { throw fail("ZIP文件过短") }
        var eocd:Int?
        for p in stride(from:data.count-22,through:max(0,data.count-65_557),by:-1) {
            if try u32(p)==0x06054b50, p+22+Int(try u16(p+20))==data.count { eocd=p; break }
        }
        guard let end=eocd, try u16(end+4)==0, try u16(end+6)==0 else { throw fail("不支持分卷或损坏ZIP") }
        let count=Int(try u16(end+10)), entriesOnDisk=Int(try u16(end+8))
        let directorySize=Int(try u32(end+12)), directoryOffset=Int(try u32(end+16))
        guard count>0,count<=20_000,count==entriesOnDisk,directorySize<Int(UInt32.max),directoryOffset<Int(UInt32.max),directoryOffset+directorySize<=end else { throw fail("不支持空ZIP、ZIP64或无效目录") }
        var result:[AppUpdateZIPEntry]=[]; var seen=Set<String>(); var cursor=directoryOffset; var expanded:UInt64=0
        for _ in 0..<count {
            guard cursor+46<=directoryOffset+directorySize,try u32(cursor)==0x02014b50 else { throw fail("ZIP中央目录损坏") }
            let flags=try u16(cursor+8), method=try u16(cursor+10), size=try u32(cursor+24)
            let n=Int(try u16(cursor+28)), e=Int(try u16(cursor+30)), c=Int(try u16(cursor+32))
            let disk=try u16(cursor+34), attrs=try u32(cursor+38), localOffset=Int(try u32(cursor+42))
            guard flags&1==0, method==0 || method==8, disk==0,size<UInt32.max,n<=4096,cursor+46+n+e+c<=directoryOffset+directorySize else { throw fail("拒绝加密、未知压缩、ZIP64或跨卷条目") }
            guard let name=String(data:data.subdata(in:cursor+46..<cursor+46+n),encoding:.utf8),safePath(name) else { throw fail("ZIP路径无效或越界") }
            let normalized=name.hasSuffix("/") ? String(name.dropLast()) : name
            guard seen.insert(normalized.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw fail("ZIP含重复路径") }
            // Check local header filename matches the central directory to prevent parser disagreement.
            guard localOffset+30<=directoryOffset,try u32(localOffset)==0x04034b50 else { throw fail("ZIP本地文件头损坏") }
            let localNameCount=Int(try u16(localOffset+26)), localExtraCount=Int(try u16(localOffset+28))
            guard localOffset+30+localNameCount+localExtraCount<=directoryOffset,try u16(localOffset+6)==flags,try u16(localOffset+8)==method,try safeExtras(cursor+46+n,e),try safeExtras(localOffset+30+localNameCount,localExtraCount), data.subdata(in:localOffset+30..<localOffset+30+localNameCount)==data.subdata(in:cursor+46..<cursor+46+n) else { throw fail("ZIP本地与中央文件名不一致") }
            let kind=(attrs>>16)&0xf000
            guard kind==0 || kind==0x8000 || kind==0x4000 || kind==0xa000 else { throw fail("ZIP包含特殊设备/管道条目") }
            expanded+=UInt64(size); guard expanded<=maximumExpandedBytes else { throw fail("ZIP解压体积超过上限") }
            result.append(AppUpdateZIPEntry(path:normalized,isSymlink:kind==0xa000,uncompressedBytes:size))
            cursor+=46+n+e+c
        }
        guard cursor==directoryOffset+directorySize else { throw fail("ZIP目录大小不匹配") }
        // No extraction entry may traverse an earlier symbolic link regardless of archive ordering.
        let links=result.filter(\.isSymlink)
        for entry in result { if links.contains(where:{$0.path != entry.path && entry.path.precomposedStringWithCanonicalMapping.lowercased().hasPrefix($0.path.precomposedStringWithCanonicalMapping.lowercased()+"/")}) { throw fail("ZIP条目经过符号链接祖先") } }
        return result
    }
    public static func safePath(_ name:String) -> Bool {
        guard !name.isEmpty,!name.hasPrefix("/"),!name.contains("\\"),!name.contains(":"),!name.contains("\0"),!name.contains(where:{"*?[]".contains($0)}) else { return false }
        let components=name.split(separator:"/",omittingEmptySubsequences:false)
        guard components.count<=40 else { return false }
        return components.enumerated().allSatisfy { index,p in p != ".." && p != "." && (!p.isEmpty || index==components.count-1) }
    }
    public static func validateSymlinkTarget(_ target:String,entryPath:String) -> Bool {
        guard !target.isEmpty,!target.hasPrefix("/"),!target.contains("\\"),!target.contains(":"),!target.contains("\0") else { return false }
        var stack=entryPath.split(separator:"/").dropLast().map(String.init)
        for part in target.split(separator:"/") {
            if part=="." { continue }
            if part==".." { guard !stack.isEmpty else { return false }; stack.removeLast() }
            else { stack.append(String(part)) }
        }
        return !stack.isEmpty
    }
}
