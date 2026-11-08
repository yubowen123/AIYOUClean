import Foundation
import CleanRoomCore
struct Regression:Error {}
func checkHistory() throws {
    let base = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("history-" + UUID().uuidString)
    let home = base.appendingPathComponent("home"), files = home.appendingPathComponent("Downloads")
    let fm = FileManager.default
    try fm.createDirectory(at:files,withIntermediateDirectories:true)
    defer { try? fm.removeItem(at:base) }
    var items:[ScanItem] = []
    for i in 0..<201 {
        let path=files.appendingPathComponent("file-\(i).txt"); try Data("fixture".utf8).write(to:path)
        items.append(ScanItem(path:path.path,category:"generated fixture",canTrash:true,identity:FileSafety.identity(path),scopeRoot:files.path))
    }
    let manager=TrashManager(storageURL:base.appendingPathComponent("state/history.json"),home:home,testTrash:base.appendingPathComponent("trash"))
    let result=manager.trash(items)
    guard result.errors.isEmpty,result.records.count==201 else{print(result.errors.prefix(2));throw Regression()}
    let count=manager.records().count
    print("History loaded by default:",count)
    if count>200 { print("FAIL: history view source is unbounded; expected at most 200 rows"); throw Regression() }
}
do { try checkHistory(); print("PASS bounded history") } catch { exit(1) }
