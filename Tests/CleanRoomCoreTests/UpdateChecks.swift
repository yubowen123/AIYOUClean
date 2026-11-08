import Foundation
import CryptoKit
import CleanRoomCore

private struct UpdateMockTransport:AppUpdateTransport {
    let feed:Data
    let archive:Data
    func fetch(_ url:URL,maximumBytes:Int64) async throws -> Data { feed }
    func download(_ url:URL,to destination:URL,maximumBytes:Int64) async throws { try archive.write(to:destination) }
}
private actor UpdateConcurrencyTransport:AppUpdateTransport {
    let feed:Data
    var active=0
    var peak=0
    init(feed:Data) { self.feed=feed }
    func fetch(_ url:URL,maximumBytes:Int64) async throws -> Data {
        active+=1; peak=max(active,peak)
        defer { active-=1 }
        try await Task.sleep(nanoseconds:20_000_000); return feed
    }
    func download(_ url:URL,to destination:URL,maximumBytes:Int64) async throws { throw AppUpdateError.invalid("not used") }
}
private final class UpdateResultBox<T>:@unchecked Sendable {
    let lock=NSLock(); var value:Result<T,Error>?
    func store(_ result:Result<T,Error>) { lock.lock(); value=result; lock.unlock() }
    func result() -> Result<T,Error>? { lock.lock(); defer {lock.unlock()}; return value }
}
private func updateWait<T:Sendable>(_ body:@escaping @Sendable () async throws -> T) throws -> T {
    let box=UpdateResultBox<T>(); let semaphore=DispatchSemaphore(value:0)
    let task=Task.detached {
        do { box.store(.success(try await body())) } catch { box.store(.failure(error)) }; semaphore.signal()
    }
    guard semaphore.wait(timeout:.now()+10) == .success else { task.cancel(); throw AppUpdateError.invalid("mock update check timed out") }
    return try unwrap(box.result()).get()
}
private struct UpdateZipFixture {
    let path:String
    let body:Data
    let mode:UInt32
    init(_ path:String,_ body:Data=Data("fixture".utf8),mode:UInt32=0x81a4) { self.path=path; self.body=body; self.mode=mode }
}
private func updateZip(_ entries:[UpdateZipFixture]) -> Data {
    func append16(_ v:UInt16,to d:inout Data) { d.append(UInt8(v&255));d.append(UInt8((v>>8)&255)) }
    func append32(_ v:UInt32,to d:inout Data) { append16(UInt16(v&65535),to:&d);append16(UInt16((v>>16)&65535),to:&d) }
    var local=Data(),central=Data()
    for entry in entries {
        let path=Data(entry.path.utf8),offset=UInt32(local.count)
        append32(0x04034b50,to:&local);append16(20,to:&local);append16(0,to:&local);append16(0,to:&local)
        append16(0,to:&local);append16(0,to:&local);append32(0,to:&local)
        append32(UInt32(entry.body.count),to:&local);append32(UInt32(entry.body.count),to:&local)
        append16(UInt16(path.count),to:&local);append16(0,to:&local);local.append(path);local.append(entry.body)
        append32(0x02014b50,to:&central);append16(0x0314,to:&central);append16(20,to:&central);append16(0,to:&central);append16(0,to:&central)
        append16(0,to:&central);append16(0,to:&central);append32(0,to:&central)
        append32(UInt32(entry.body.count),to:&central);append32(UInt32(entry.body.count),to:&central)
        append16(UInt16(path.count),to:&central);append16(0,to:&central);append16(0,to:&central)
        append16(0,to:&central);append16(0,to:&central);append32(entry.mode<<16,to:&central);append32(offset,to:&central);central.append(path)
    }
    let centralOffset=UInt32(local.count); local.append(central)
    append32(0x06054b50,to:&local);append16(0,to:&local);append16(0,to:&local)
    append16(UInt16(entries.count),to:&local);append16(UInt16(entries.count),to:&local)
    append32(UInt32(central.count),to:&local);append32(centralOffset,to:&local);append16(0,to:&local)
    return local
}

/// Called by the shared standalone runner. Uses generated fixtures and mock transport only.
func runUpdateChecks() throws {
    checkEqual(AppUpdateVersion.compare("001.10.0","1.9"),.orderedDescending)
    checkEqual(AppUpdateVersion.compare("1.0","1.0.0"),.orderedSame)
    checkEqual(AppUpdateVersion.compare("999999999999999999999999","10"),.orderedDescending)
    checkTrue(AppUpdateVersion.compare("release-beta","1")==nil)
    checkThrows(try AppUpdateURLPolicy.validate(URL(string:"http://vendor.example/feed")!))
    checkThrows(try AppUpdateURLPolicy.validate(URL(string:"https://user:password@vendor.example/feed")!))
    try AppUpdateURLPolicy.validate(URL(string:"https://vendor.example/feed")!)
    let target=AppUpdateTarget(path:"/not-installed/Example.app",name:"Example",bundleID:"example.update.fixture",version:"1",build:"100",feedURL:URL(string:"https://vendor.example/feed"))
    let xml="""
    <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><title>Compatible release</title><sparkle:version>110</sparkle:version><sparkle:shortVersionString>1.1</sparkle:shortVersionString><sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion><sparkle:maximumSystemVersion>30.0.0</sparkle:maximumSystemVersion><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements><enclosure url="https://vendor.example/fixture.zip" length="7" sparkle:edSignature="fixture"/></item>
    <item><sparkle:version>999</sparkle:version><sparkle:channel>beta</sparkle:channel><enclosure url="https://vendor.example/beta.zip"/></item>
    <item><sparkle:version>888</sparkle:version><enclosure url="https://vendor.example/delta.zip" sparkle:deltaFrom="100"/></item>
    </channel></rss>
    """
    let data=Data(xml.utf8), releases=try AppUpdateAppcast.parse(data)
    checkEqual(releases.count,3)
    let chosen=try AppUpdateAppcast.select(releases,target:target,osVersion:"26.0.0",architecture:"arm64")
    checkEqual(chosen.0?.version,"110")
    let intel=try AppUpdateAppcast.select(releases,target:target,osVersion:"26.0.0",architecture:"x86_64")
    checkTrue(intel.0==nil);checkTrue(intel.1)
    let beta=try AppUpdateAppcast.select(releases,target:target,osVersion:"26.0.0",architecture:"arm64",allowedChannels:["beta"])
    checkEqual(beta.0?.version,"999")
    let oldOS=try AppUpdateAppcast.select(releases,target:target,osVersion:"12.0.0",architecture:"arm64")
    checkTrue(oldOS.0==nil)
    checkThrows(try AppUpdateAppcast.parse(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss/>".utf8)))
    checkThrows(try AppUpdateAppcast.parse(Data("<rss><item>".utf8)))
    checkThrows(try AppUpdateAppcast.parse(Data(repeating:65,count:4_194_305)))
    checkThrows(try AppUpdateAppcast.select([.init(version:"not-a-build",archiveURL:URL(string:"https://vendor.example/app.zip"))],target:target,osVersion:"26.0",architecture:"arm64"))
    checkThrows(try AppUpdateAppcast.select([.init(version:"111",archiveURL:URL(string:"http://vendor.example/app.zip"))],target:target,osVersion:"26.0",architecture:"arm64"))
    let service=AppUpdateService(transport:UpdateMockTransport(feed:data,archive:Data()))
    let check=try updateWait { await service.check(target) };checkEqual(check.state,.updateAvailable)
    let emptyService=AppUpdateService(transport:UpdateMockTransport(feed:Data("<rss><channel/></rss>".utf8),archive:Data()))
    let empty=try updateWait { await emptyService.check(target) };checkEqual(empty.state,.failed)
    let missing=AppUpdateTarget(path:target.path,name:target.name,bundleID:target.bundleID,version:target.version,build:target.build,feedURL:nil,distribution:.unknown)
    let missingResult=try updateWait { await service.check(missing) };checkEqual(missingResult.state,.noSource)
    let store=AppUpdateTarget(path:target.path,name:target.name,bundleID:target.bundleID,version:target.version,build:target.build,feedURL:nil,distribution:.appStore)
    let storeResult=try updateWait { await service.check(store) };checkEqual(storeResult.state,.appStore)
    let concurrent=UpdateConcurrencyTransport(feed:data);let concurrentService=AppUpdateService(transport:concurrent)
    let (count,peak)=try updateWait { let result=await concurrentService.checkAll(Array(repeating:target,count:8),concurrency:99); return (result.count,await concurrent.peak) }
    checkEqual(count,8);checkTrue(peak<=2)
    let key=Curve25519.Signing.PrivateKey(),payload=Data("signed update fixture".utf8)
    let signature=try key.signature(for:payload).base64EncodedString(),publicKey=key.publicKey.rawRepresentation.base64EncodedString()
    try AppUpdateService.verifyArchive(payload,publicKey:publicKey,signature:signature)
    checkThrows(try AppUpdateService.verifyArchive(Data("changed fixture".utf8),publicKey:publicKey,signature:signature))
    let good=updateZip([.init("Example.app/Contents/Info.plist")]);checkEqual(try AppUpdateZIP.entries(good).count,1)
    for name in ["../escape","/absolute","A/../escape","A\\escape","A//x",String(repeating:"a/",count:41)+"x"] {
        checkThrows(try AppUpdateZIP.entries(updateZip([.init(name)])))
    }
    checkThrows(try AppUpdateZIP.entries(updateZip([.init("A"),.init("a")])))
    checkThrows(try AppUpdateZIP.entries(updateZip([.init("Link",Data("Destination".utf8),mode:0xa1ff),.init("link/file")])))
    checkThrows(try AppUpdateZIP.entries(updateZip([.init("device",mode:0x21a4)])))
    checkThrows(try AppUpdateZIP.entries(good,maximumExpandedBytes:1))
    checkFalse(AppUpdateZIP.validateSymlinkTarget("../../outside",entryPath:"Example.app/link"))
    checkTrue(AppUpdateZIP.validateSymlinkTarget("Versions/Current/Library",entryPath:"Example.app/Frameworks/Library"))
    checkTrue(AppUpdateZIP.validateSymlinkTarget("A",entryPath:"Example.app/Versions/Current"))
    // Source inventory is intentionally metadata-only: no recursive app size traversal or network access.
    let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture=project.appendingPathComponent(".test-fixtures/update-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:fixture) }
    let app=fixture.appendingPathComponent("Fixture.app/Contents")
    try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
    let info:[String:Any]=["CFBundleIdentifier":"example.fixture.update","CFBundleName":"Fixture","CFBundleVersion":"1","CFBundleShortVersionString":"1.0","SUFeedURL":"https://vendor.example/feed"]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Info.plist"))
    let list=service.inventory(roots:[fixture]);checkEqual(list.count,1);checkEqual(list.first?.distribution,.sparkle)
    // The injected network only copies generated bytes; signed archive verifies and tamper stops preparation.
    let signedTarget=AppUpdateTarget(path:target.path,name:target.name,bundleID:target.bundleID,version:target.version,build:target.build,feedURL:target.feedURL,sparklePublicKey:publicKey)
    let release=AppcastRelease(version:"110",archiveURL:URL(string:"https://vendor.example/app.zip"),edSignature:signature,length:Int64(payload.count))
    let available=AppUpdateCheck(target:signedTarget,state:.updateAvailable,release:release)
    let downloader=AppUpdateService(transport:UpdateMockTransport(feed:data,archive:payload),storageRoot:fixture.appendingPathComponent("cache"))
    let downloaded=try updateWait { try await downloader.download(available) };checkTrue(downloaded.signatureVerified)
    try Data("tampered".utf8).write(to:downloaded.archiveURL)
    checkThrows(try downloader.prepare(downloaded))
    // Failed preparation must release its global heavy-work permit, and contention fails before extraction.
    if let permit=WorkBudget.tryAcquire("update-check fixture contention") {
        do { _=try downloader.prepare(downloaded); checkTrue(false) }
        catch { checkTrue(error.localizedDescription.contains("正在运行")) }
        permit.release()
        let again=WorkBudget.tryAcquire("update-check permit release")
        checkTrue(again != nil); again?.release()
    } else { checkTrue(false) }
    print("PASS update checks (bounded appcast, numeric builds, system/architecture/channel filters, signed archive, ZIP paths, metadata inventory, mocked network concurrency<=2)")
}
