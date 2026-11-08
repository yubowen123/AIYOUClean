import Foundation
import Darwin
import CleanRoomCore

private final class LensCheckCancellation:@unchecked Sendable {
    private let lock=NSLock();private var calls=0;let after:Int
    init(after:Int) {self.after=after}
    func check() -> Bool {lock.lock();defer {lock.unlock()};calls+=1;return calls>after}
}
private func lensAllocated(_ url:URL) -> Int64 {var value=stat();guard lstat(url.path,&value)==0 else {return -1};return max(0,Int64(value.st_blocks))*512}
func runSpaceLensChecks() throws {
    let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture=project.appendingPathComponent(".test-fixtures/space-lens-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:fixture)}
    let home=fixture.appendingPathComponent("fake-home"),root=fixture.appendingPathComponent("content"),a=root.appendingPathComponent("a"),z=root.appendingPathComponent("z")
    for folder in [home,a,z,root.appendingPathComponent("empty")] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
    let original=z.appendingPathComponent("original.bin"),hardlink=a.appendingPathComponent("linked.bin"),unique=root.appendingPathComponent("unique.bin")
    try Data(repeating:7,count:8192).write(to:original);try FileManager.default.linkItem(at:original,to:hardlink)
    try Data(repeating:8,count:4096).write(to:unique)
    let outside=fixture.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
    try Data(repeating:9,count:16384).write(to:outside.appendingPathComponent("excluded.bin"))
    let link=root.appendingPathComponent("outside-link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
    let service=SpaceLensService()
    var references:[ScanResultReference]=[]
    defer {for reference in references {try? SpaceLensResultStore.remove(reference)}}
    func analyzed(root:URL,limits:SpaceLensLimits = .init(),home:URL,isCancelled:@escaping @Sendable ()->Bool={false}) -> SpaceLensReport {
        let value=service.scan(root:root,limits:limits,home:home,isCancelled:isCancelled)
        if let reference=value.resultStore {references.append(reference)}
        return value
    }
    let report=analyzed(root:root,home:home)
    checkFalse(report.incomplete);checkEqual(report.logicalBytes,12288);checkEqual(report.duplicateHardLinks,1)
    checkEqual(report.items.count,5)
    let aItem=try unwrap(report.items.first {$0.name=="a"}),zItem=try unwrap(report.items.first {$0.name=="z"})
    checkEqual(aItem.logicalBytes,8192);checkEqual(zItem.logicalBytes,0)
    checkEqual(report.items.first {$0.name=="outside-link"}?.state,.skippedSymlink)
    checkTrue(report.items.first {$0.name=="outside-link"}?.logicalBytes==nil)
    checkEqual(report.items.first {$0.name=="empty"}?.logicalBytes,0)
    checkEqual(report.items.first {$0.name=="empty"}?.state,.complete)
    let expectedAllocated=lensAllocated(a)+lensAllocated(z)+lensAllocated(root.appendingPathComponent("empty"))+lensAllocated(original)+lensAllocated(unique)
    checkEqual(report.allocatedBytes,expectedAllocated)
    // Entering the folder is an independent report, not a retained tree of every descendant.
    let disposable = analyzed(root: a, home: home)
    let disposableRef = try unwrap(disposable.resultStore)
    checkThrows(try ScanResultStore.remove(disposableRef))
    try SpaceLensResultStore.remove(disposableRef)
    checkFalse(FileManager.default.fileExists(atPath: disposableRef.path))
    try SpaceLensResultStore.remove(disposableRef) // Idempotent owned disposal.
    let entered=analyzed(root:a,home:home);checkEqual(entered.items.count,1);checkEqual(entered.logicalBytes,8192)
    let cancelled=analyzed(root:root,home:home,isCancelled:{true});checkTrue(cancelled.incomplete);checkTrue(cancelled.items.isEmpty)
    let limited=analyzed(root:root,limits:.init(maxEntries:2,scanToCompletion:false),home:home)
    checkTrue(limited.incomplete);checkTrue(limited.visitedEntries<=2)
    checkTrue(limited.items.allSatisfy {$0.state != .unscanned || ($0.logicalBytes==nil && $0.allocatedBytes==nil)})
    let timeLimited=analyzed(root:root,limits:.init(maxSeconds:0,scanToCompletion:false),home:home);checkTrue(timeLimited.incomplete)
    let memoryLimited=analyzed(root:root,limits:.init(maxRSSBytes:1,scanToCompletion:false),home:home);checkTrue(memoryLimited.incomplete);checkTrue(memoryLimited.items.isEmpty)
    let childLimited=analyzed(root:root,limits:.init(maxChildren:2),home:home);checkFalse(childLimited.incomplete);checkTrue(childLimited.items.count<=2);checkEqual(childLimited.totalItemCount,5);checkEqual(childLimited.logicalBytes,12288)
    let symlinkRoot=analyzed(root:link,home:home);checkTrue(symlinkRoot.incomplete);checkTrue(symlinkRoot.items.isEmpty)
    // Explicit and persisted ignores both prune the entire directory subtree; roots fail without fake zero.
    let ignored=analyzed(root:root,limits:.init(excludedPaths:[a.path,z.path]),home:home)
    checkEqual(ignored.logicalBytes,4096);checkTrue(ignored.items.allSatisfy {$0.path != a.path && $0.path != z.path});checkTrue(ignored.ignoredEntries>=2)
    try IgnoreRuleStore(home:home).save([root.path])
    let ignoredRoot=analyzed(root:root,home:home);checkTrue(ignoredRoot.incomplete);checkTrue(ignoredRoot.items.isEmpty)
    try IgnoreRuleStore(home:home).save([a.path])
    let stored=analyzed(root:root,home:home);checkTrue(stored.items.allSatisfy {$0.path != a.path});checkEqual(stored.logicalBytes,12288)
    let rulesURL=IgnoreRuleStore(home:home).fileURL
    try Data("not valid JSON".utf8).write(to:rulesURL)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:rulesURL.path)
    let broken=analyzed(root:root,home:home);checkTrue(broken.incomplete);checkTrue(broken.items.isEmpty);checkTrue(broken.warnings.contains {$0.contains("忽略")})
    try IgnoreRuleStore(home:home).save([])
    let permit=try unwrap(WorkBudget.tryAcquire("space-lens fixture contention"))
    let blocked=analyzed(root:root,home:home);checkTrue(blocked.incomplete);checkTrue(blocked.items.isEmpty);permit.release()
    let after=WorkBudget.tryAcquire("space-lens fixture release");checkTrue(after != nil);after?.release()
    // Previously the 2000-child cap stopped retrieval. A tiny preview and tiny
    // diagnostic thresholds now cannot stop the default continuous traversal.
    let flat=fixture.appendingPathComponent("many-direct-children")
    try FileManager.default.createDirectory(at:flat,withIntermediateDirectories:true)
    for index in 0..<3001 {
        try autoreleasepool {
            let url=flat.appendingPathComponent(String(format:"entry-%05d",index))
            let fd=open(url.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
            guard fd>=0 else {throw CheckError.missingValue}
            defer {close(fd)}
            checkEqual(ftruncate(fd,64),0)
        }
    }
    let continuous=analyzed(root:flat,limits:.init(maxEntries:2,maxSeconds:0,maxRSSBytes:1,maxChildren:2),home:home)
    checkFalse(continuous.incomplete);checkEqual(continuous.visitedEntries,3001)
    checkEqual(continuous.items.count,2);checkEqual(continuous.totalItemCount,3001)
    checkEqual(continuous.logicalBytes,3001*64)
    let spaceStore=try SpaceLensResultStore(reference:try unwrap(continuous.resultStore))
    let lastPage=try spaceStore.page(offset:3000,metric:.logical)
    checkEqual(lastPage.totalCount,3001);checkEqual(lastPage.items.count,1)
    checkEqual(lastPage.items[0].name,"entry-03000")
    checkEqual(try spaceStore.item(path:lastPage.items[0].path)?.logicalBytes,64)
    var persistedCount=0,persistedBytes:Int64=0
    try spaceStore.forEachItem {item in persistedCount+=1;persistedBytes+=item.logicalBytes ?? 0}
    checkEqual(persistedCount,3001);checkEqual(persistedBytes,3001*64)
    let map=try spaceStore.mapData(metric:.logical)
    checkEqual(map.items.count,95);checkEqual(map.remainingCount,2906)
    let mapped=SpaceLensLayout.rectangles(items:map.items,width:1,height:1,metric:.logical,remainingCount:map.remainingCount,remainingBytes:map.remainingBytes)
    checkEqual(mapped.count,96);checkTrue(mapped.contains {$0.path==nil})
    checkTrue(abs(mapped.reduce(0.0) {$0+$1.rect.area}-1)<0.000001)
    checkEqual(mapped.reduce(Int64(0)) {$0+$1.bytes},3001*64)
    checkThrows(try spaceStore.page(isCancelled:{true}))
    let stop=LensCheckCancellation(after:50)
    let midCancelled=analyzed(root:flat,home:home,isCancelled:{stop.check()})
    checkTrue(midCancelled.incomplete);checkTrue(midCancelled.visitedEntries>0);checkTrue(midCancelled.visitedEntries<3001)
    // The former 128-level recursion cap was replaced by a disk directory queue.
    let deep=fixture.appendingPathComponent("deep-tree")
    try FileManager.default.createDirectory(at:deep,withIntermediateDirectories:true)
    var leaf=deep
    for _ in 0..<150 {leaf.appendPathComponent("d");try FileManager.default.createDirectory(at:leaf,withIntermediateDirectories:false)}
    try Data(repeating:1,count:13).write(to:leaf.appendingPathComponent("leaf"))
    let deepReport=analyzed(root:deep,home:home)
    checkFalse(deepReport.incomplete);checkEqual(deepReport.logicalBytes,13);checkEqual(deepReport.visitedEntries,151)
    // Pure layout: rectangles retain weight area and stay inside finite bounds; zero/unknown never masquerade as a tile.
    let items=[SpaceLensItem(path:"/generated/a",name:"a",kind:.file,state:.complete,logicalBytes:30,allocatedBytes:30),SpaceLensItem(path:"/generated/b",name:"b",kind:.file,state:.complete,logicalBytes:70,allocatedBytes:70),SpaceLensItem(path:"/generated/zero",name:"zero",kind:.file,state:.complete,logicalBytes:0,allocatedBytes:0),SpaceLensItem(path:"/generated/unknown",name:"unknown",kind:.directory,state:.unscanned,logicalBytes:nil,allocatedBytes:nil)]
    let tiles=SpaceLensLayout.rectangles(items:items,width:100,height:40)
    checkEqual(tiles.count,2)
    checkTrue(abs(tiles.reduce(0.0) {$0+$1.rect.area}-4000)<0.001)
    let first=try unwrap(tiles.first {$0.path=="/generated/a"});checkTrue(abs(first.rect.area-1200)<0.001)
    for tile in tiles {checkTrue(tile.rect.x>=0 && tile.rect.y>=0 && tile.rect.width>=0 && tile.rect.height>=0);checkTrue(tile.rect.x+tile.rect.width<=100.00001 && tile.rect.y+tile.rect.height<=40.00001)}
    checkTrue(SpaceLensLayout.rectangles(items:items,width:0,height:40).isEmpty)
    checkTrue(SpaceLensLayout.rectangles(items:items,width:Double.nan,height:40).isEmpty)
    checkTrue(SpaceLensLayout.rectangles(items:Array(items.suffix(2)),width:100,height:40).isEmpty)
    let grouped=SpaceLensLayout.rectangles(items:items,width:100,height:40,maxTiles:1)
    checkEqual(grouped.count,1);checkTrue(grouped[0].path==nil);checkEqual(grouped[0].bytes,100)
    print("PASS space-lens checks (hardlink allocation, logical/allocated sizes, no-follow navigation, ignore/cancel/diagnostic/budget, continuous disk pages and directory queue, bounded area layout and unknown/zero boundaries)")
}
