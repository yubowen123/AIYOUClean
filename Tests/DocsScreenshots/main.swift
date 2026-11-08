import AppKit
import SwiftUI
import Vision
import CleanRoomCore

// Constructible equivalents only for seeding documentation metadata. The
// production SmartCareView layout and bounded SQLite page reader are unchanged.
struct DocsModuleSummary: Identifiable, Sendable {
    var id: ScanKind { kind }
    let kind: ScanKind
    let count: Int, processableCount: Int, readOnlyCount: Int
    let permissionRequired: Bool
    let bytes: Int64
    let visitedFiles: Int
    let warnings: [String], observations: [String]
    let incomplete: Bool, skipped: Bool
}
struct DocsSmartReport: Sendable {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var finishedAt = Date(timeIntervalSince1970: 1_700_000_020)
    var modules: [DocsModuleSummary] = []
    var items: [ScanItem] = []
    var resultStore: ScanResultReference?
    var readOnlyStore: ScanResultReference?
    var readOnlyStoredCount = 0
    var diskCoverage: FullDiskCoverage?
    var totalItemCount = 0
    var totalProcessableBytes: Int64 = 0
    var warnings: [String] = []
    var visitedFiles = 0
    var incomplete = false, cancelled = false, invalidated = false
    var peakResidentBytes: UInt64 = 0
    var appliedIgnoreRules: [String] = []
    var readOnlyItemCount: Int { modules.reduce(0) { $0 + $1.readOnlyCount } }
    var permissionRequiredModuleCount: Int { modules.filter(\.permissionRequired).count }
}
struct DocsSnapshot: Sendable {
    let host = "Demo Mac", os = "macOS · 演示数据"
    let totalDisk: Int64 = 1_000_000_000_000, availableDisk: Int64 = 400_000_000_000
    let totalMemory: UInt64 = 32_000_000_000
    let processors = 8, uptime: TimeInterval = 86400
    let loadAverage = "0.00", battery = "100% · 演示数据"
}
enum DocsFixture { static func snapshot() -> DocsSnapshot { DocsSnapshot() } }
enum DocsFailure: Error { case arguments, bitmap, page(String), text(String) }

@main struct DocsScreenshots {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw DocsFailure.arguments }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("AIYOUClean-docs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var references: [ScanResultReference] = []
        defer {
            for ref in references { try? ScanResultStore.remove(ref) }
            try? FileManager.default.removeItem(at: fakeHome)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let processable = [
            ScanItem(path: "/Users/demo/Library/Caches/ExampleEditor", name: "ExampleEditor", category: "用户缓存", bytes: 2_400_000_000, detail: "示例数据：请在清理前关闭对应应用并检查内容。", canTrash: true),
            ScanItem(path: "/Users/demo/Library/Developer/Xcode/DerivedData/DemoApp", name: "DemoApp · DerivedData", category: "开发缓存", bytes: 1_600_000_000, detail: "示例构建缓存；后续构建可能重新生成。", canTrash: true),
            ScanItem(path: "/Users/demo/Downloads/demo-install.dmg", name: "demo-install.dmg", category: "大文件", bytes: 1_200_000_000, detail: "示例安装包；由你决定是否仍需保留。", canTrash: true),
            ScanItem(path: "/Users/demo/Documents/素材/示例视频-副本.mov", name: "示例视频-副本.mov", category: "重复文件", bytes: 860_000_000, detail: "示例内容一致候选；每组固定保留一份。", group: "demo-01", canTrash: true, retainedPath: "/Users/demo/Documents/素材/示例视频.mov"),
            ScanItem(path: "/Users/demo/Library/Logs/DemoApp", name: "DemoApp 日志", category: "用户日志", bytes: 230_000_000, detail: "示例日志内容，清理前仍需逐项核对。", canTrash: true),
            ScanItem(path: "/Users/demo/Movies/示例旧项目.zip", name: "示例旧项目.zip", category: "旧文件", bytes: 180_000_000, detail: "示例旧文件；时间较久不代表没有价值。", canTrash: true),
        ]
        let readOnly = [
            ScanItem(path: "/System/Library/AssetsV2/demo-asset", name: "系统资源 · 示例", category: "只读发现", bytes: 4_000_000_000, detail: "受保护的系统内容，仅供查看。"),
            ScanItem(path: "/Applications/DemoEditor.app/Contents/Resources", name: "应用包资源 · 示例", category: "只读发现", bytes: 1_800_000_000, detail: "应用包内部内容不作为普通文件清理候选。"),
            ScanItem(path: "/Users/demo/Library/Application Support/DemoApp/data.db", name: "应用数据 · 示例", category: "只读发现", bytes: 640_000_000, detail: "普通应用数据仅展示占用，不默认作为垃圾。"),
        ]
        let issues = [
            ScanItem(path: "/Users/demo/Library/Mail", name: "Mail 数据目录 · 示例", category: "访问受限", detail: "示例拒读：Operation not permitted (errno 1)。请核对文件访问权限。"),
            ScanItem(path: "/Users/demo/Documents/Cloud/demo-project", name: "尚未下载的云内容 · 示例", category: "云占位跳过", detail: "未下载到本机，不触发下载，不推测内部大小。"),
            ScanItem(path: "/Users/demo/Documents/linked-folder", name: "符号链接 · 示例", category: "链接跳过", detail: "不跟随链接，避免跨越扫描范围。"),
            ScanItem(path: "/Users/demo/Documents/保留资料", name: "忽略目录 · 示例", category: "按规则忽略", detail: "用户排除的路径，不读取或处理。"),
        ]
        func stored(_ items: [ScanItem]) throws -> ScanResultReference {
            let store = try ScanResultStore.createTemporary()
            references.append(store.reference)
            for row in items { try store.append(row) }
            try store.flush(); return store.reference
        }
        var fixture = DocsSmartReport()
        fixture.items = processable
        fixture.resultStore = try stored(processable)
        fixture.readOnlyStore = try stored(readOnly)
        fixture.readOnlyStoredCount = readOnly.count
        fixture.totalItemCount = processable.count
        fixture.totalProcessableBytes = processable.reduce(0) { $0 + $1.bytes }
        fixture.visitedFiles = 12480
        fixture.incomplete = true
        fixture.diskCoverage = FullDiskCoverage(roots: ["/", "/Volumes/DemoSSD"], notes: ["演示范围与数量，未实际扫描磁盘。"], visitedEntries: 12480, regularFiles: 10420, logicalBytes: 384_000_000_000, inaccessibleEntries: 1, skippedCloudEntries: 1, skippedLinkEntries: 1, excludedEntries: 1, incomplete: true, issueStore: try stored(issues), issueCount: issues.count)
        fixture.modules = [.init(kind: .cleanup, count: 6, processableCount: 6, readOnlyCount: 3, permissionRequired: true, bytes: fixture.totalProcessableBytes, visitedFiles: 12480, warnings: ["演示数据：没有扫描用户磁盘。"], observations: [], incomplete: true, skipped: false)]
        var results: [[String: Any]] = []
        for (name, mode, required) in [("smart-processable", SmartCareResultMode.processable, "清理所选"), ("smart-readonly", .readOnly, "只读发现仅供查看"), ("smart-issues", .issues, "访问问题仅供查看")] {
            let center = DetectionTaskCenter(), registry = FeatureStateRegistry(tasks: center)
            let state: SmartCareViewState = registry.retain("smartCare") { SmartCareViewState(taskCenter: center, home: fakeHome) }
            state.report = fixture; state.pageItemCount = processable.count; state.resultMode = mode
            state.resolvedCounts = [.processable: processable.count, .readOnly: readOnly.count, .issues: issues.count]
            let view = SmartCareView(registry: registry)
            let rendered = try render(view, output: output.appendingPathComponent(name + ".png"), label: "智能检查 · " + mode.title) {
                try spin { !state.pageLoading }
                if let error = state.pageError { throw DocsFailure.page(error) }
                if mode == .processable { for row in state.pageItems.prefix(2) { state.toggle(row) } }
            }
            guard rendered.contains(where: { $0.contains(required) }) else { throw DocsFailure.text(name + ": " + required) }
            results.append(["image": name + ".png", "contentView": "SmartCareView", "mode": mode.rawValue, "rows": state.pageItems.count, "selected": state.selected.count, "footerTextVerified": required])
        }
        let state = AppState(taskCenter: DetectionTaskCenter(), trashManagerFactory: { TrashManager(storageURL: fakeHome.appendingPathComponent("history.sqlite3"), home: fakeHome, testTrash: fakeHome.appendingPathComponent(".Trash")) })
        state.destination = .scan(.duplicates)
        state.roots = [URL(fileURLWithPath: "/Users/demo/Documents/素材")]
        let duplicates = [
            ScanItem(path: "/Users/demo/Documents/素材/示例视频-副本.mov", name: "示例视频-副本.mov", category: "重复文件", bytes: 860_000_000, detail: "SHA-256 一致 · 示例组1 · 每组保留一份", group: "demo-01", canTrash: true, retainedPath: "/Users/demo/Documents/素材/示例视频.mov"),
            ScanItem(path: "/Users/demo/Documents/素材/海报-副本.png", name: "海报-副本.png", category: "重复文件", bytes: 32_000_000, detail: "SHA-256 一致 · 示例组2 · 每组保留一份", group: "demo-02", canTrash: true, retainedPath: "/Users/demo/Documents/素材/海报.png"),
            ScanItem(path: "/Users/demo/Documents/素材/音效-副本.wav", name: "音效-副本.wav", category: "重复文件", bytes: 18_000_000, detail: "SHA-256 一致 · 示例组3 · 每组保留一份", group: "demo-03", canTrash: true, retainedPath: "/Users/demo/Documents/素材/音效.wav"),
        ]
        let report = ScanReport(kind: .duplicates, items: duplicates, visitedFiles: 24)
        state.acceptReport(report)
        let rendered = try render(ScanView().environmentObject(state), output: output.appendingPathComponent("duplicates.png"), label: "重复文件 · 按内容校验") {
            try spin { !state.pageLoading }
            for row in state.visibleItems.prefix(1) { state.toggle(row) }
        }
        guard rendered.contains(where: { $0.contains("清理所选") }) else { throw DocsFailure.text("duplicates footer") }
        results.append(["image": "duplicates.png", "contentView": "ScanView", "rows": state.visibleItems.count, "selected": state.selected.count, "footerTextVerified": "清理所选"])
        try JSONSerialization.data(withJSONObject: ["passed": true, "screenshots": results, "allDataGenerated": true], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("screenshots-check.json"))
    }
    @MainActor static func spin(until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            if Date() > deadline { throw DocsFailure.page("timeout") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    @MainActor static func render<V: View>(_ view: V, output: URL, label: String, prepare: () throws -> Void) throws -> [String] {
        let root = VStack(spacing: 0) {
            HStack {
                Text("AIYOUClean 0.6.2").font(.system(size: 13, weight: .semibold))
                Text("/  " + label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("演示数据").font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4).background(Color.white.opacity(0.07), in: Capsule())
            }.padding(.horizontal, 24).frame(height: 46).background(Color(red: 0.105, green: 0.12, blue: 0.18))
            view
        }.frame(width: 1000, height: 820).preferredColorScheme(.dark).background(Color(red: 0.055, green: 0.065, blue: 0.12)).tint(Color(red: 0.61, green: 0.49, blue: 1))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.setContentSize(NSSize(width: 1000, height: 820)); window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25)); host.layoutSubtreeIfNeeded()
        try prepare()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DocsFailure.bitmap }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), let cg = bitmap.cgImage else { throw DocsFailure.bitmap }
        try png.write(to: output)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "") }
    }
}
