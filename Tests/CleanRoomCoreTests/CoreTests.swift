import Foundation
import CoreGraphics
import ImageIO
import CleanRoomCore

final class CoreTests {
    var root: URL!
    var home: URL!
    var files: URL!
    var reportStores: [ScanResultReference] = []
    let fm = FileManager.default
    func setUpWithError() throws {
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".test-fixtures/" + UUID().uuidString)
        home = root.appendingPathComponent("home"); files = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at:files,withIntermediateDirectories:true)
    }
    func tearDownWithError() throws { for reference in reportStores { try? ScanResultStore.remove(reference) }; reportStores = []; if let root { try fm.removeItem(at:root) } }
    @discardableResult func write(_ name:String, _ data:Data = Data("sample".utf8), under:URL? = nil) throws -> URL {
        let u = (under ?? files).appendingPathComponent(name)
        try fm.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:u); return u
    }
    func report(_ kind:ScanKind, maxFiles:Int = 100_000) -> ScanReport {
        let report = Scanner().scan(kind,options:ScanOptions(home:home,roots:[files],maxFiles:maxFiles,largeFileBytes:4,scanToCompletion:false))
        if let reference = report.resultStore { reportStores.append(reference) }
        return report
    }
    func manager() -> TrashManager { TrashManager(storageURL:root.appendingPathComponent("state/history.json"),home:home,testTrash:root.appendingPathComponent("isolated-trash")) }
    func testDuplicateHashAndKeepOne() throws {
        try write("a.txt"); try write("b.txt"); try write("c.txt",Data("unique".utf8))
        let r = report(.duplicates)
        checkEqual(r.items.count,2)
        checkEqual(r.items.filter(\.canTrash).count,1)
        let m = manager(); let outcome = m.trash(r.items)
        checkEqual(outcome.records.count,1); checkEqual(outcome.errors.count,1)
        checkTrue(fm.fileExists(atPath:files.appendingPathComponent("a.txt").path))
        checkTrue(fm.fileExists(atPath:files.appendingPathComponent("c.txt").path))
    }
    func testChangedDuplicateKeeperRejectsRemoval() throws {
        let a = try write("a"); try write("b")
        let r = report(.duplicates)
        try Data("changed".utf8).write(to:a)
        let outcome = manager().trash(r.items.filter(\.canTrash))
        checkEqual(outcome.records.count,0); checkEqual(outcome.errors.count,1)
    }
    func testHardLinksNotReclaimableDuplicates() throws {
        let a = try write("a"); try fm.linkItem(at:a,to:files.appendingPathComponent("hardlink"))
        checkEqual(report(.duplicates).items.count,0)
    }
    func testTrashAndRestoreExactContent() throws {
        let u = try write("retain.txt",Data("preserved bytes".utf8))
        let item = try unwrap(report(.downloads).items.first)
        let m = manager(); let out = m.trash([item])
        checkTrue(out.errors.isEmpty); checkEqual(out.records.count,1)
        checkFalse(fm.fileExists(atPath:u.path)); checkEqual(m.records().count,1)
        try m.restore(try unwrap(out.records.first))
        checkEqual(try Data(contentsOf:u),Data("preserved bytes".utf8)); checkEqual(m.records().count,0)
    }
    func testRestoreRefusesOverwrite() throws {
        let u = try write("x")
        let m = manager(); let out = m.trash(report(.downloads).items)
        try Data("new data".utf8).write(to:u)
        checkThrows(try m.restore(unwrap(out.records.first)))
        checkEqual(try Data(contentsOf:u),Data("new data".utf8)); checkEqual(m.records().count,1)
    }
    func testChangedFileRejected() throws {
        let u = try write("x"); let item = try unwrap(report(.downloads).items.first)
        try Data("new".utf8).write(to:u)
        let out = manager().trash([item]); checkEqual(out.records.count,0); checkEqual(out.errors.count,1)
        checkTrue(fm.fileExists(atPath:u.path))
    }
    func testSymlinkNotTraversed() throws {
        let outside = root.appendingPathComponent("outside"); try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        let secret = try write("keep",under:outside)
        try fm.createSymbolicLink(at:files.appendingPathComponent("link"),withDestinationURL:outside)
        checkFalse(report(.largeFiles).items.contains { $0.path == secret.path || $0.path.contains("/link/") })
        checkTrue(report(.downloads).items.isEmpty)
    }
    func testReplacingParentWithSymlinkRejected() throws {
        let inner = files.appendingPathComponent("inner"); let u = try write("x",under:inner)
        let r = report(.largeFiles); let item = try unwrap(r.items.first { $0.path == u.path })
        let moved = files.appendingPathComponent("moved"); try fm.moveItem(at:inner,to:moved)
        try fm.createSymbolicLink(at:inner,withDestinationURL:moved)
        let out = manager().trash([item]); checkEqual(out.records.count,0)
        checkTrue(fm.fileExists(atPath:moved.appendingPathComponent("x").path))
    }
    func testProtectedHomeRejected() {
        let item = ScanItem(path:home.path,category:"fake",canTrash:true,identity:FileSafety.identity(home),scopeRoot:root.path)
        checkEqual(manager().trash([item]).records.count,0)
    }
    func testRootBoundaryUsesComponentNotStringPrefix() throws {
        let sibling = home.appendingPathComponent("Downloads-other"); let u = try write("x",under:sibling)
        let item = ScanItem(path:u.path,category:"fake",canTrash:true,identity:FileSafety.identity(u),scopeRoot:files.path)
        checkEqual(manager().trash([item]).records.count,0)
    }
    func testOverlappingSelectionsRejected() throws {
        let inner = files.appendingPathComponent("inner"); let u = try write("x",under:inner)
        let parent = ScanItem(path:inner.path,category:"x",canTrash:true,identity:FileSafety.identity(inner),scopeRoot:files.path)
        let child = ScanItem(path:u.path,category:"x",canTrash:true,identity:FileSafety.identity(u),scopeRoot:files.path)
        let out = manager().trash([parent,child]); checkEqual(out.records.count,0); checkEqual(out.errors.count,2)
    }
    func testTruncationAndCancellationReported() throws {
        for i in 0..<10 { try write("\(i)") }
        let truncated = report(.largeFiles,maxFiles:2)
        checkTrue(truncated.truncated); checkFalse(truncated.warnings.isEmpty)
        let cancelled = Scanner().scan(.duplicates,options:ScanOptions(home:home,roots:[files]),isCancelled:{true})
        checkTrue(cancelled.truncated); checkTrue(cancelled.items.isEmpty)
    }
    func testSpaceStatsAndNoDeletion() throws {
        try write("one",Data(repeating:1,count:32)); try write("two",Data(repeating:1,count:64))
        let r = report(.spaceLens)
        checkEqual(r.totalBytes,96); checkTrue(r.items.allSatisfy { !$0.canTrash })
    }
    func testApplicationsPreciseSupportFiles() throws {
        let app = files.appendingPathComponent("Example.app")
        let info: [String:Any] = ["CFBundleIdentifier":"example.fixture.app","CFBundleShortVersionString":"1.0"]
        try write("Contents/Info.plist",PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0),under:app)
        let preferences = home.appendingPathComponent("Library/Preferences")
        try write("example.fixture.app.plist",under:preferences)
        try write("example.fixture.app.other.plist",under:preferences)
        let r = report(.applications)
        checkEqual(r.items.filter { $0.category == "应用程序" }.count,1)
        checkEqual(r.items.filter { $0.category == "精确 ID 支持文件" }.count,1)
    }
    func testMalformedStartupPlistProducesWarning() throws {
        try write("broken.plist",Data("not plist".utf8))
        let r = report(.startup); checkEqual(r.items.count,0); checkFalse(r.warnings.isEmpty)
    }
    func testCommandTimeout() {
        let start = Date(); let r = CommandRunner.run("/bin/sleep",["2"],timeout:0.08)
        checkEqual(r.code,-2); checkLessThan(Date().timeIntervalSince(start),1.8)
    }
    func testJSONRoundTripIncludesLimits() throws {
        try write("x")
        let r = report(.downloads); let d = try JSONEncoder().encode(r); let copy = try JSONDecoder().decode(ScanReport.self,from:d)
        checkEqual(copy.items,r.items); checkEqual(copy.visitedFiles,r.visitedFiles)
    }
    func testSimilarImageCandidates() throws {
        var pixels = [UInt8](repeating:0,count:32*32*4)
        for y in 0..<32 { for x in 0..<32 { let i = (y*32+x)*4; pixels[i] = UInt8(x*7); pixels[i+1] = UInt8(y*7); pixels[i+2] = UInt8((x+y)*3); pixels[i+3] = 255 } }
        let image = pixels.withUnsafeMutableBytes { b -> CGImage? in CGContext(data:b.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() }
        let img = try unwrap(image)
        for name in ["a.png","b.png"] {
            let url = files.appendingPathComponent(name)
            let dst = try unwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(dst,img,nil); checkTrue(CGImageDestinationFinalize(dst))
        }
        let r = report(.similarImages); checkEqual(r.items.count,2); checkEqual(r.items.filter(\.canTrash).count,1)
    }
    func testMacOSTrashAndRestoreIntegration() throws {
        let u = try write("cleanroom-generated-trash-test.txt",Data("disposable integration fixture".utf8))
        let item = try unwrap(report(.downloads).items.first)
        let m = TrashManager(storageURL:root.appendingPathComponent("state/system-history.json"))
        let outcome = m.trash([item])
        checkTrue(outcome.errors.isEmpty)
        let record = try unwrap(outcome.records.first)
        checkFalse(fm.fileExists(atPath:u.path))
        do { try m.restore(record) } catch {
            // Only this generated fixture is eligible for direct recovery after a failed test.
            if fm.fileExists(atPath:record.trashPath) && !fm.fileExists(atPath:u.path) {
                try? fm.moveItem(atPath:record.trashPath,toPath:u.path)
            }
            throw error
        }
        checkEqual(try Data(contentsOf:u),Data("disposable integration fixture".utf8))
        checkTrue(m.records().isEmpty)
    }

    func testRestoreRejectsReplacedParentDirectory() throws {
        let inner = files.appendingPathComponent("inner")
        try write("x",under:inner)
        let item = try unwrap(report(.largeFiles).items.first)
        let m = manager(); let out = m.trash([item]); let record = try unwrap(out.records.first)
        try fm.moveItem(at:inner,to:files.appendingPathComponent("former-inner"))
        try fm.createDirectory(at:inner,withIntermediateDirectories:true)
        checkThrows(try m.restore(record)); checkEqual(m.records().count,1)
    }
    func testRestoreRejectsChangedTrashItem() throws {
        try write("x")
        let m = manager(); let out = m.trash(report(.downloads).items); let record = try unwrap(out.records.first)
        try Data("replacement data".utf8).write(to:URL(fileURLWithPath:record.trashPath))
        checkThrows(try m.restore(record)); checkEqual(m.records().count,1)
    }

    func testApplicationSizeIncludesNestedFramework() throws {
        let app = files.appendingPathComponent("Nested.app")
        let info: [String:Any] = ["CFBundleIdentifier":"example.fixture.nested","CFBundleShortVersionString":"1.0"]
        try write("Contents/Info.plist",PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0),under:app)
        try write("Contents/Frameworks/Demo.framework/Versions/A/Demo",Data(repeating:7,count:4096),under:app)
        let r = report(.applications)
        let item = try unwrap(r.items.first { $0.path == app.path })
        checkTrue(item.bytes >= 4096)
    }

}
