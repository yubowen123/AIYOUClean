import Foundation
import CleanRoomCore
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
func usage() {
    print("""
    AIYOUClean — 只读扫描 CLI
    aiyouclean-cli scan KIND [--full] [--root PATH] [--home PATH] [--max-files N] [--max-seconds N] [--max-results N] [--memory-mb N] [--output JSON_PATH]
    aiyouclean-cli status
    KIND: \(ProductFeatures.availableScanKinds.map(\.rawValue).joined(separator:", "))
    默认持续扫描；结果落盘分页，--max-results 仅调整预览大小。--max-files/--max-seconds 用于显式的有界诊断，--full 恢复完整扫描。
    不提供删除、授权补丁或隐式管理员操作。所有路径参数直接传递，不执行 shell。
    """)
}
if args.first == "status" {
    let s = SystemInfo.snapshot()
    print("\(s.os)\nDisk available: \(Format.bytes(s.availableDisk)) / \(Format.bytes(s.totalDisk))\nRAM installed: \(Format.bytes(Int64(s.totalMemory)))\nLoad 1/5/15m: \(s.loadAverage)\n\(s.battery)")
} else if args.first == "scan", args.count > 1, let kind = ScanKind(rawValue:args[1]) {
    guard ProductFeatures.allows(kind) else { fputs("此功能当前未提供产品入口。\n", stderr); exit(2) }
    var options = ScanOptions()
    var output: URL?
    var i = 2
    while i < args.count {
        if args[i] == "--full" { options.maxFiles = Int.max; options.maxSeconds = .infinity; options.scanToCompletion = true; i += 1; continue }
        guard i + 1 < args.count else { fputs("缺少参数值\n",stderr); exit(2) }
        let value = args[i+1]
        switch args[i] {
        case "--root": options.roots.append(URL(fileURLWithPath:value))
        case "--home": options.home = URL(fileURLWithPath:value).standardizedFileURL
        case "--max-files": guard let n = Int(value), n > 0 else { exit(2) }; options.maxFiles = n; options.scanToCompletion = false
        case "--max-seconds": guard let n = Double(value), n > 0 else { exit(2) }; options.maxSeconds = n; options.scanToCompletion = false
        case "--max-results": guard let n = Int(value), (1...30000).contains(n) else { exit(2) }; options.maxResults = n
        case "--memory-mb": guard let n = UInt64(value), (32...8192).contains(n) else { exit(2) }; options.memoryBudgetBytes = n * 1024 * 1024
        case "--output": output = URL(fileURLWithPath:value)
        default: usage(); exit(2)
        }
        i += 2
    }
    let report: ScanReport
    if kind == .spaceLens {
        guard options.roots.count <= 1 else { fputs("空间分析每次只接收一个根目录。\n", stderr); exit(2) }
        let lens = SpaceLensService().scan(root: options.roots.first ?? options.home, limits: .init(maxEntries: options.maxFiles, maxSeconds: options.maxSeconds, maxRSSBytes: options.memoryBudgetBytes, maxChildren: options.maxResults, excludedPaths: options.excludedPaths, scanToCompletion: options.scanToCompletion), home: options.home)
        var value = ScanReport(kind: kind, startedAt: lens.startedAt, warnings: lens.warnings, visitedFiles: lens.visitedEntries, truncated: lens.incomplete)
        value.finishedAt = lens.finishedAt; value.peakResidentBytes = lens.peakRSSBytes
        value.memoryBudgetBytes = options.memoryBudgetBytes; value.resultLimit = min(200, options.maxResults)
        let converted = try? ScanResultStore.createTemporary()
        do {
            func append(_ item: SpaceLensItem) throws {
                try converted?.append(ScanItem(path: item.path, name: item.name, category: item.state.title, bytes: item.allocatedBytes ?? 0, detail: "分配量：" + (item.allocatedBytes.map(Format.bytes) ?? "未知") + " · 逻辑文件量：" + (item.logicalBytes.map(Format.bytes) ?? "未知"), canTrash: false))
            }
            if let reference = lens.resultStore {
                defer { try? SpaceLensResultStore.remove(reference) }
                let source = try SpaceLensResultStore(reference: reference)
                try source.forEachItem { try append($0) }
            } else { for item in lens.items { try append(item) } }
            guard let converted else { throw ScanStoreError.rejected("无法建立导出结果索引。") }
            try converted.flush()
            let page = try converted.page(limit: min(200, options.maxResults))
            value.items = page.items; value.resultStore = converted.reference
            value.totalItemCount = page.statistics.totalCount; value.processableItemCount = 0; value.allItemsBytes = page.statistics.totalBytes
        } catch {
            if let reference = converted?.reference { try? ScanResultStore.remove(reference) }
            fputs("空间分析导出失败：\(error.localizedDescription)\n", stderr); exit(1)
        }
        report = value
    } else { report = Scanner().scan(kind,options:options) }
    defer { if let reference = report.resultStore { try? ScanResultStore.remove(reference) } }
    do {
        if let output {
            try ScanReportExporter.write(report, to: output); print(output.path)
        } else {
            guard let rawTemp = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ScanStoreError.rejected("无法解析临时目录。") }
            let canonicalTemp = URL(fileURLWithPath: String(cString: rawTemp), isDirectory: true); free(rawTemp)
            let directory = canonicalTemp.appendingPathComponent("AIYOUClean-CLI-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let temporary = directory.appendingPathComponent("report.json")
            try ScanReportExporter.write(report, to: temporary)
            let input = try FileHandle(forReadingFrom: temporary); defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty { try FileHandle.standardOutput.write(contentsOf: chunk) }
        }
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
    if report.truncated { if let reference = report.resultStore { try? ScanResultStore.remove(reference) }; exit(3) }
} else { usage(); if !args.isEmpty { exit(2) } }
