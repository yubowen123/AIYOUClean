import AppKit
import SwiftUI
import Vision
import CleanRoomCore

// Only the temporary GUI copy uses these constructible report/scope types. No
// real scan or external account is needed to exercise production layout/state.
enum LayoutFixtureScanScope: String, CaseIterable, Sendable, Identifiable {
    case allLocalDisks, selectedFolders, localMaintenance
    var id: String { rawValue }
    var title: String { self == .allLocalDisks ? "全盘检查" : (self == .selectedFolders ? "自选文件夹" : "局部维护") }
}
struct LayoutFixtureModuleSummary: Identifiable, Sendable {
    var id: ScanKind { kind }
    let kind: ScanKind
    let count: Int
    let processableCount: Int
    let readOnlyCount: Int
    let permissionRequired: Bool
    let bytes: Int64
    let visitedFiles: Int
    let warnings: [String]
    let observations: [String]
    let incomplete: Bool
    let skipped: Bool
}
struct LayoutFixtureDiskCoverage: Sendable {
    var roots: [String]
    var notes: [String]
    var visitedEntries: Int
    var regularFiles: Int
    var logicalBytes: Int64
    var inaccessibleEntries: Int
    var issueCount: Int = 0
    var skippedCloudEntries: Int
    var skippedLinkEntries: Int
    var excludedEntries: Int
    var incomplete: Bool
    var cancelled: Bool
    var issueStore: LayoutFixtureStoreReference? = nil
}
struct LayoutFixtureReport: Sendable {
    var modules: [LayoutFixtureModuleSummary] = []
    var items: [ScanItem] = []
    var resultStore: LayoutFixtureStoreReference? = nil
    var totalItemCount = 0
    var totalProcessableBytes: Int64 = 0
    var warnings: [String] = []
    var visitedFiles = 0
    var incomplete = false
    var cancelled = false
    var invalidated = false
    var peakResidentBytes: UInt64 = 0
    var appliedIgnoreRules: [String] = []
    var diskCoverage: LayoutFixtureDiskCoverage?
    var readOnlyStore: LayoutFixtureStoreReference? = nil
    var readOnlyStoredCount = 0
    var readOnlyRows: [ScanItem] = []
    var issueRows: [ScanItem] = []
    var readOnlyItemCount: Int { modules.reduce(0) { $0 + $1.readOnlyCount } }
    var permissionRequiredModuleCount: Int { modules.filter(\.permissionRequired).count }
    func rows(for mode: SmartCareResultMode) -> [ScanItem] {
        switch mode { case .processable: return items; case .readOnly: return readOnlyRows; case .issues: return issueRows }
    }
    var references: [LayoutFixtureStoreReference] { [resultStore, readOnlyStore, diskCoverage?.issueStore].compactMap { $0 } }
    static func generated() -> Self {
        let items = (1...31).map { index in
            ScanItem(path: "/generated-smart-care-layout-fixture/Library/Caches/模拟候选-\(index)/内容", name: "生成的清理候选 \(index)", category: "模拟缓存", bytes: Int64(index) * 1024 * 1024, detail: "仅用于布局；不读取或删除用户文件。", canTrash: true)
        }
        // One hostile canTrash flag verifies that the UI mode guard, not a
        // backend hint, controls whether read-only/issue rows can be selected.
        let readOnly = (1...11).map { ScanItem(path: "/generated-smart-care-layout-fixture/System/只读文件-\($0)", name: "系统只读发现 \($0)", category: "只读发现", bytes: 2_000_000, detail: "系统与其他用户受保护内容仅供查看。", canTrash: $0 == 1) }
        let issues = (1...3).map { ScanItem(path: "/generated-smart-care-layout-fixture/OtherUser/拒读目录-\($0)", name: "未能访问的目录 \($0)", category: "访问问题", detail: "Operation not permitted (errno=1)。不能仅凭此错误断定缺少完整磁盘访问。", canTrash: $0 == 1) } + [
            ScanItem(path: "/generated-smart-care-layout-fixture/Skipped/cloud-placeholder", name: "跳过未下载内容", category: "云占位跳过", detail: "未下载到本机，不触发下载。"),
            ScanItem(path: "/generated-smart-care-layout-fixture/Skipped/ignored-by-rule", name: "已按规则忽略", category: "忽略", detail: "用户规则排除，不读取此路径。"),
            ScanItem(path: "/generated-smart-care-layout-fixture/Skipped/symbolic-link", name: "跳过符号链接", category: "链接跳过", detail: "不跟随链接进入其他范围。")
        ]
        let warnings = ["生成的拒读范围：未读取目录可能包含更多内容，不能视为全盘已完成。"] + (1...79).map { "长提示\($0)：生成的扫描范围与权限说明，默认收起，不遮住候选和固定操作栏。" }
        return Self(modules: [
            .init(kind: .cleanup, count: 31, processableCount: 31, readOnlyCount: 0, permissionRequired: true, bytes: items.reduce(0) { $0 + $1.bytes }, visitedFiles: 1_300_000, warnings: warnings, observations: [], incomplete: true, skipped: false),
            .init(kind: .protection, count: 4, processableCount: 0, readOnlyCount: 4, permissionRequired: false, bytes: 0, visitedFiles: 4, warnings: ["生成的系统配置，不执行系统命令。"], observations: ["模拟只读状态"], incomplete: false, skipped: false)
        ], items: items, totalItemCount: 31, totalProcessableBytes: items.reduce(0) { $0 + $1.bytes }, warnings: ["生成的部分范围提示；已有31项候选仍可复查。"], visitedFiles: 1_300_004, incomplete: true,
                    diskCoverage: .init(roots: ["/", "/Volumes/FixtureSSD", "/Volumes/FixtureArchive"], notes: ["生成的范围数据，不读取用户磁盘。", "不可访问目录及其内容未完成检查。"], visitedEntries: 1_300_000, regularFiles: 1_200_031, logicalBytes: 4_000_000_000_000, inaccessibleEntries: 3, issueCount: 6, skippedCloudEntries: 1, skippedLinkEntries: 1, excludedEntries: 1, incomplete: true, cancelled: false),
                    readOnlyStoredCount: 11, readOnlyRows: readOnly, issueRows: issues)
    }
}

@main struct SmartCareLayoutChecks {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw LayoutFailure.arguments }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        var results: [[String: Any]] = []
        var allPassed = true
        let scenarios: [(String, NSSize, SmartCareResultMode, LayoutFixtureScanScope, Bool)] = [
            ("processable-1080x730", NSSize(width: 1080, height: 730), .processable, .allLocalDisks, false),
            ("processable-1220x820", NSSize(width: 1220, height: 820), .processable, .allLocalDisks, false),
            ("readonly-1080x730", NSSize(width: 1080, height: 730), .readOnly, .allLocalDisks, false),
            ("readonly-1220x820", NSSize(width: 1220, height: 820), .readOnly, .allLocalDisks, false),
            ("issues-1080x730", NSSize(width: 1080, height: 730), .issues, .allLocalDisks, false),
            ("issues-1220x820", NSSize(width: 1220, height: 820), .issues, .allLocalDisks, false),
            ("coverage-expanded-1220x820", NSSize(width: 1220, height: 820), .issues, .allLocalDisks, true),
            ("selected-folders-1220x820", NSSize(width: 1220, height: 820), .processable, .selectedFolders, false)
        ]
        for (name, size, mode, scope, expanded) in scenarios {
            try autoreleasepool {
            SmartCareLayoutProbe.frames = [:]
            var fixture = LayoutFixtureReport.generated()
            if scope == .selectedFolders { fixture.diskCoverage?.roots = ["/generated-selected-folders/Work", "/generated-selected-folders/Media"] }
            let references = try makeLayoutFixtureStores(items: fixture.items, readOnly: fixture.readOnlyRows, issues: fixture.issueRows)
            fixture.resultStore = references.0; fixture.readOnlyStore = references.1; fixture.diskCoverage?.issueStore = references.2
            let state = SmartCareViewState()
            let defaultsToFullDisk = state.scanScope == .allLocalDisks && state.canStartScan
            state.seedLayoutFixture(fixture, mode: .processable, scope: scope)
            for item in fixture.items.prefix(2) { state.toggle(item) }
            state.requestTrash()
            let confirmationWasCreated = state.confirmation != nil
            state.setResultMode(.readOnly)
            let clearedOnModeChange = state.selected.isEmpty && state.confirmation == nil
            state.setResultMode(mode)
            try settlePage(state)
            if mode == .processable { for item in state.pageItems.prefix(2) { state.toggle(item) } }
            else {
                if let item = state.pageItems.first { state.toggle(item) }
                state.selectPage(); state.requestTrash()
            }
            let modeCannotClean = mode == .processable || (state.selected.isEmpty && state.selectedItems.isEmpty && state.confirmation == nil)
            let root = HStack(spacing: 0) {
                Color(red: 0.07, green: 0.075, blue: 0.13).frame(width: 235)
                SmartCareView(layoutState: state, expandCoverage: expanded).background(Color(red: 0.06, green: 0.07, blue: 0.12))
            }.preferredColorScheme(.dark).background(SmartCareLayoutProbe(name: "root"))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "AIYOUClean全盘检查布局夹具（不扫描、不清理）"; window.contentView = host
            window.setContentSize(size); window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LayoutFailure.bitmap }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]), let image = bitmap.cgImage else { throw LayoutFailure.bitmap }
            try data.write(to: output.appendingPathComponent("smart-care-\(name).png"))
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let recognized = (request.results ?? []).compactMap { observation -> [String: Any]? in
                guard let text = observation.topCandidates(1).first else { return nil }
                return ["text": text.string, "confidence": Double(text.confidence), "box": rectJSON(observation.boundingBox)]
            }
            let texts = recognized.compactMap { $0["text"] as? String }.map { $0.filter { !$0.isWhitespace } }
            let origin = SmartCareLayoutProbe.frames["root"]?.origin ?? .zero
            let frames = SmartCareLayoutProbe.frames.mapValues { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            let bounds = CGRect(origin: .zero, size: size)
            let required = ["root", "summary", "scope", "coverage", "permissionNotice", "permissionEntry", "modes", "candidates", "footer"] + (mode == .processable ? ["cleanup"] : [])
            let markerChecks = Dictionary(uniqueKeysWithValues: required.map { ($0, visible(frames[$0], in: bounds)) })
            let list = frames["candidates"] ?? .zero, footer = frames["footer"] ?? .zero
            let checks: [String: Bool] = [
                "defaultsToFullDisk": defaultsToFullDisk,
                "requestedScopeUsed": state.scanScope == scope,
                "modeClearsSelectionAndConfirmation": confirmationWasCreated && clearedOnModeChange,
                "readonlyAndIssuesCannotClean": modeCannotClean,
                "pageBoundedTo200": state.pageItems.count <= 200,
                "pageCountMatchesCategory": state.pageItemCount == fixture.rows(for: mode).count,
                "issueTabCountsAllCoverageEvents": state.modeCount(.issues) == fixture.issueRows.count && state.modeCount(.issues) == 6 && fixture.diskCoverage?.inaccessibleEntries == 3,
                "summaryOCR": texts.contains { $0.contains("可处理") && $0.contains("31") },
                "fullDiskChoiceOCR": texts.contains { $0.contains("全盘检查") },
                "permissionsEntryOCR": texts.contains { $0.contains("权限引导") },
                "inaccessibleCountOCR": texts.contains { $0.contains("不可访问3") },
                "coverageEventCountOCR": texts.contains { $0.contains("访问问题6") },
                "allRequiredMarkersVisible": markerChecks.values.allSatisfy { $0 },
                "candidateViewportHasHeight": list.height >= (expanded ? 35 : 80),
                "footerDoesNotOverlapCandidates": list.maxY <= footer.minY + 1,
                "cleanupVisibleOnlyForProcessable": mode == .processable ? texts.contains { $0.contains("清理所选") } : frames["cleanup"] == nil,
                "modeRowsOCR": mode == .processable || texts.contains { $0.contains(mode == .readOnly ? "系统只读发现" : "未能访问的目录") },
                "expandedRootsOCR": !expanded || texts.contains { $0.contains("FixtureSSD") },
                "incompleteNotCalledComplete": fixture.incomplete && fixture.diskCoverage?.incomplete == true && texts.contains { $0.contains("部分范围未完成读取") }
            ]
            let passed = checks.values.allSatisfy { $0 }; allPassed = allPassed && passed
            results.append(["scenario": name, "widthPoints": Double(size.width), "heightPoints": Double(size.height), "mode": mode.rawValue, "scope": scope.rawValue,
                            "coverageExpanded": expanded, "markers": frames.mapValues(rectJSON), "markerChecks": markerChecks, "checks": checks, "passed": passed,
                            "selected": state.selected.count, "pageItems": state.pageItems.count, "pageItemCount": state.pageItemCount,
                            "screenshot": "smart-care-\(name).png", "ocr": recognized])
            try jsonData(recognized).write(to: output.appendingPathComponent("ocr-\(name).json"))
            window.orderOut(nil); state.stopOnDisappear()
            try waitForLayoutFixtureRemoval(fixture.references)
            window.close(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            print("\(passed ? "PASS" : "FAIL") \(name): \(checks)")
            }
        }
        // Scope invalidation is checked with a fresh owned report, independently
        // of window presentation. No file dialog or scanner is ever invoked.
        var scopeFixture = LayoutFixtureReport.generated()
        let scopeRefs = try makeLayoutFixtureStores(items: scopeFixture.items, readOnly: scopeFixture.readOnlyRows, issues: scopeFixture.issueRows)
        scopeFixture.resultStore = scopeRefs.0; scopeFixture.readOnlyStore = scopeRefs.1; scopeFixture.diskCoverage?.issueStore = scopeRefs.2
        let scopeState = SmartCareViewState(); scopeState.seedLayoutFixture(scopeFixture, mode: .processable, scope: .allLocalDisks)
        scopeState.toggle(scopeFixture.items[0]); scopeState.requestTrash(); scopeState.setScanScope(.selectedFolders)
        let scopeInvalidates = scopeState.report == nil && scopeState.selected.isEmpty && scopeState.confirmation == nil && !scopeState.canStartScan
        scopeState.setScanScope(.allLocalDisks); scopeState.setScanScope(.localMaintenance)
        let noLocalDefault = scopeState.scanScope == .allLocalDisks && scopeState.canStartScan
        try waitForLayoutFixtureRemoval(scopeFixture.references)
        allPassed = allPassed && scopeInvalidates && noLocalDefault
        try jsonData(["passed": allPassed, "scenarios": results, "scopeChangeInvalidates": scopeInvalidates, "localMaintenanceNotExposed": noLocalDefault]).write(to: output.appendingPathComponent("layout-results.json"))
        if !allPassed { exit(1) }
    }
    @MainActor private static func settlePage(_ state: SmartCareViewState) throws {
        let deadline = Date().addingTimeInterval(5)
        while state.pageLoading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if state.pageLoading || state.pageError != nil { throw LayoutFailure.page(state.pageError ?? "timeout") }
    }
    private static func visible(_ rectangle: CGRect?, in bounds: CGRect) -> Bool {
        guard let rectangle, rectangle.width > 8, rectangle.height > 8 else { return false }
        return rectangle.minX >= -0.5 && rectangle.minY >= -0.5 && rectangle.maxX <= bounds.width + 0.5 && rectangle.maxY <= bounds.height + 0.5
    }
    private static func rectJSON(_ r: CGRect) -> [String: Double] { ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)] }
    private static func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
}
enum LayoutFailure: Error { case arguments, bitmap, page(String) }
@MainActor struct SmartCareLayoutProbe: View {
    static var frames: [String: CGRect] = [:]
    let name: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.onAppear { Self.frames[name] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { Self.frames[name] = $0 }
        }
    }
}
