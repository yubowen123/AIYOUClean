import AppKit
import SwiftUI
import Vision
import CleanRoomCore

@main struct LayoutChecks {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [[String: Any]] = []
        var allPassed = true
        for size in [NSSize(width: 1080, height: 730), NSSize(width: 1220, height: 820)] {
            for backgroundBusy in [false, true] {
                try autoreleasepool {
                    LayoutProbe.frames = [:]; LayoutEnabledProbe.values = [:]
                    let center = DetectionTaskCenter(), state = AppState(taskCenter: center)
                    let items = (0..<38).map { ScanItem(path: "/generated-layout-fixture/cache/entry-\($0)", category: "模拟缓存", bytes: Int64($0 + 1) * 1024, canTrash: true) }
                    let report = ScanReport(kind: .cleanup, items: items, warnings: ["生成的部分范围提示；此报告不对应真实文件，不执行扫描或清理。"], visitedFiles: 100_000, truncated: true)
                    state.destination = .scan(.cleanup); state.acceptReport(report)
                    var job: UUID?
                    let host = NSHostingView(rootView: MainView().environmentObject(state).preferredColorScheme(.dark).background(LayoutProbe(name: "root")))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.title = "AIYOUClean 布局检查（生成数据）"; window.contentView = host
                    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
                    defer { if let job { center.finish(job) }; window.orderOut(nil); window.close(); settle(0.03) }
                    settle(0.3); host.layoutSubtreeIfNeeded()
                    for _ in 0..<3 {
                        let current = window.contentLayoutRect.size
                        if abs(current.width - size.width) < 0.5 && abs(current.height - size.height) < 0.5 { break }
                        var frame = window.frame; frame.size.width += size.width - current.width; frame.size.height += size.height - current.height
                        window.setFrame(frame, display: false); settle(0.05); host.layoutSubtreeIfNeeded()
                    }
                    // MainView's first appearance refreshes its page/selection.
                    // Select after that refresh, then start the foreign ticket.
                    for item in state.visibleItems.prefix(2) { state.toggle(item) }
                    if backgroundBusy {
                        job = center.begin("生成的另一页后台任务", destination: .smartCare, cancel: nil)
                        if let job { center.update(job, count: 1200, path: "仅用于布局，无真实工作线程", phase: "生成的任务进度") }
                    }
                    settle(0.05); host.layoutSubtreeIfNeeded()
                    let viewport = host.convert(window.contentLayoutRect, from: nil)
                    guard let root = LayoutProbe.frames["root"] else { throw CheckFailure.geometry }
                    let frames = LayoutProbe.frames.mapValues { $0.offsetBy(dx: -root.minX - viewport.minX, dy: -root.minY - viewport.minY) }
                    let bounds = CGRect(origin: .zero, size: size)
                    let required = ["scan", "list", "footer", "cleanup", "sidebar"] + (backgroundBusy ? ["taskBanner"] : [])
                    let visible = Dictionary(uniqueKeysWithValues: required.map { ($0, inside(frames[$0], bounds)) })
                    let list = frames["list"] ?? .zero, footer = frames["footer"] ?? .zero
                    let cleanup = frames["cleanup"] ?? .zero
                    let name = "\(Int(size.width))x\(Int(size.height))-" + (backgroundBusy ? "other-task" : "idle")
                    let png = output.deletingPathExtension().appendingPathExtension(name + ".png")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure.noBitmap }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]), let image = bitmap.cgImage else { throw CheckFailure.noBitmap }
                    try data.write(to: png)
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let labels = (request.results ?? []).compactMap { observation -> [String: Any]? in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return ["text": text, "box": rect(observation.boundingBox)]
                    }
                    let cleanupLabels = labels.filter { ($0["text"] as? String ?? "").filter { !$0.isWhitespace }.contains("清理所选") }
                    let checks: [String: Bool] = [
                        "requestedContentViewport": abs(viewport.width - size.width) < 0.5 && abs(viewport.height - size.height) < 0.5,
                        "allRequiredMarkersVisible": visible.values.allSatisfy { $0 },
                        "footerContainsCleanup": footer.insetBy(dx: -1, dy: -1).contains(cleanup),
                        "footerDoesNotOverlapList": list.maxY <= footer.minY + 1,
                        "listHasUsableHeight": list.height >= 80,
                        "cleanupLabelRendered": !cleanupLabels.isEmpty,
                        "selectedRowsPreserved": state.selected.count == 2,
                        "foreignTicketPreserved": !backgroundBusy || center.active?.id == job,
                        "cleanupEnabledMatchesTaskState": LayoutEnabledProbe.values["cleanup"] == !backgroundBusy
                    ]
                    let passed = checks.values.allSatisfy { $0 }; allPassed = allPassed && passed
                    results.append(["scenario": name, "widthPoints": size.width, "heightPoints": size.height,
                                    "backgroundTaskRunning": backgroundBusy, "passed": passed, "checks": checks,
                                    "markers": frames.mapValues(rect), "markerVisibility": visible,
                                    "cleanupEnabled": LayoutEnabledProbe.values["cleanup"] ?? false,
                                    "selectedRows": state.selected.count, "renderedCleanupLabels": cleanupLabels,
                                    "screenshot": png.path, "bitmapPixels": [bitmap.pixelsWide, bitmap.pixelsHigh]])
                    print("\(passed ? "PASS" : "FAIL") \(name): \(checks), cleanupEnabled=\(LayoutEnabledProbe.values["cleanup"] ?? false)")
                }
            }
        }
        let evidence: [String: Any] = ["passed": allPassed, "scenarios": results, "realScanView": true,
                                       "otherDestinationsStubbed": true, "realFilesScannedOrCleaned": false,
                                       "limitation": "另一页运行态由独立中心票据模拟；真实跨页工作线程由task-lifecycle-check.py另行验证。",
                                       "bitmapLimitation": "离屏NSHostingView未完整捕获原生侧栏与顶部任务条的绘制；目标ScanView、底栏和清理按钮已实际渲染并核对几何。"]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        if !allPassed { exit(1) }
    }
    @MainActor private static func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private static func inside(_ value: CGRect?, _ bounds: CGRect) -> Bool {
        guard let value, value.width > 8, value.height > 8 else { return false }
        return value.minX >= -1 && value.minY >= -1 && value.maxX <= bounds.maxX + 1 && value.maxY <= bounds.maxY + 1
    }
    private static func rect(_ value: CGRect) -> [String: Double] { ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)] }
}
enum CheckFailure: Error { case arguments, noBitmap, geometry }
@MainActor struct LayoutProbe: View {
    static var frames: [String: CGRect] = [:]
    let name: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.onAppear { Self.frames[name] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { Self.frames[name] = $0 }
                .onDisappear { Self.frames[name] = nil }
        }
    }
}
@MainActor struct LayoutEnabledProbe: View {
    static var values: [String: Bool] = [:]
    @Environment(\.isEnabled) private var enabled
    let name: String
    var body: some View {
        Color.clear.onAppear { Self.values[name] = enabled }.onChange(of: enabled) { Self.values[name] = $0 }
            .onDisappear { Self.values[name] = nil }
    }
}
