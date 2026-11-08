import AppKit
import SwiftUI
import CleanRoomCore

@MainActor enum NativeScanFixture {
    static var home = URL(fileURLWithPath: "/generated-unconfigured-native-scan-home")
}
@MainActor struct NativeScaleProbe: View {
    static var frames: [String: CGRect] = [:]
    let name: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.onAppear { Self.frames[name] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { Self.frames[name] = $0 }
        }
    }
}
private enum NativeScaleFailure: LocalizedError {
    case invalid(String), timeout(String)
    var errorDescription: String? {
        switch self { case .invalid(let text), .timeout(let text): return text }
    }
}

@main struct NativeScanScaleChecks {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 7 else { print("Expected output, owned home, runtime directory, count, rounds, nonce"); exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var result: [String: Any] = ["passed": false, "visionUsed": false, "windowSizePoints": [1080, 730]]
        do {
            let home = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let runtime = URL(fileURLWithPath: CommandLine.arguments[3]).resolvingSymlinksInPath().standardizedFileURL
            guard let count = Int(CommandLine.arguments[4]), count == 12_001,
                  let rounds = Int(CommandLine.arguments[5]), (1...3).contains(rounds) else { throw NativeScaleFailure.invalid("Unexpected fixture size/rounds") }
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: home.deletingLastPathComponent().appendingPathComponent("fixture-owner.json"))) as? [String: Any]
            guard marker?["kind"] as? String == "AIYOUClean.NativeScanScaleFixture", marker?["nonce"] as? String == CommandLine.arguments[6], marker?["count"] as? Int == count,
                  home.lastPathComponent == "home", runtime.deletingLastPathComponent() == home.deletingLastPathComponent() else { throw NativeScaleFailure.invalid("Only the freshly generated fixture may be scanned") }
            let actualRuntime = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            // macOS Foundation may keep the per-user system temporary directory
            // despite TMPDIR. Core creates its own UUID/schema-validated indexes;
            // verify their real lifecycle below rather than changing Core paths.
            result["coreTemporaryDirectory"] = actualRuntime.path
            result["ownedFixtureAuxiliaryDirectory"] = runtime.path
            NativeScanFixture.home = home
            NSApplication.shared.setActivationPolicy(.prohibited)
            result["rounds"] = try measure(home: home, count: count, rounds: rounds)
            result["passed"] = true
        } catch { result["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { print("Cannot write native measurement: \(error)"); exit(2) }
        if result["passed"] as? Bool != true { print("FAIL \(result["error"] ?? "Native checks failed")"); exit(1) }
    }

    @MainActor private static func measure(home: URL, count: Int, rounds: Int) throws -> [[String: Any]] {
        let start = ProcessInfo.processInfo.systemUptime, deadline = start + 180
        let state = AppState()
        state.destination = .scan(.duplicates)
        state.setRoots([home.appendingPathComponent("Downloads")])
        let host = NSHostingView(rootView: MainView().environmentObject(state).preferredColorScheme(.dark).background(NativeScaleProbe(name: "root")))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AIYOUClean真实GUI查重内存夹具（不清理）"; window.contentView = host
        window.setContentSize(NSSize(width: 1080, height: 730))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
        defer {
            state.cancelScan(); state.suspendPresentation(); window.orderOut(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        var maximumVisible = 0, observations: [[String: Any]] = []
        func observe() { maximumVisible = max(maximumVisible, state.visibleItems.count) }
        func wait(_ description: String, until predicate: () -> Bool) throws {
            while !predicate() {
                if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeScaleFailure.timeout("180s watchdog: " + description) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02)); observe()
            }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025)); observe()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
        // NavigationSplitView changes the test window's titlebar/content style
        // after first appearance. Correct the *actual* content viewport after
        // that change; an initial NSWindow(contentRect:) alone can leave 762pt.
        for _ in 0..<3 {
            let actual = window.contentLayoutRect.size
            if abs(actual.width - 1080) < 0.5 && abs(actual.height - 730) < 0.5 { break }
            var frame = window.frame
            frame.size.width += 1080 - actual.width
            frame.size.height += 730 - actual.height
            window.setFrame(frame, display: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        }
        for round in 1...rounds {
            let roundStart = ProcessInfo.processInfo.systemUptime
            state.scan()
            guard state.busy else { throw NativeScaleFailure.invalid("Real AppState scan did not start") }
            try wait("real duplicate scan and first disk page", until: { !state.busy && !state.pageLoading })
            guard let report = state.report else { throw NativeScaleFailure.invalid("No real scan report") }
            guard report.totalItemCount == count, !report.truncated, report.stopReason == nil,
                  state.reportItemCount == count, state.processableItemCount == count - 1,
                  state.filteredCount == count, state.reportTotalBytes == Int64(count * 64),
                  state.pageError == nil, report.resultStore != nil, report.items.isEmpty,
                  report.visitedFiles >= count else { throw NativeScaleFailure.invalid("Scan totals/truncation/store invariants failed: total=\(report.totalItemCount ?? -1), truncated=\(report.truncated), UI=\(state.reportItemCount), processable=\(state.processableItemCount), pageError=\(state.pageError ?? "none"), stop=\(report.stopReason?.rawValue ?? "none"), warnings=\(report.warnings.joined(separator: " | "))") }
            let scanSeconds = ProcessInfo.processInfo.systemUptime - roundStart
            let pageCount = state.pageCount
            var seen = 0, processableSeen = 0
            var pages: [[String: Any]] = []
            var firstGeometry: [String: Any] = [:]
            var clearedOnPageChange = false
            while true {
                let offset = state.pageIndex * state.pageSize
                let expected = min(200, count - offset)
                guard state.visibleItems.count == expected, state.visibleItems.count <= 200,
                      state.filteredCount == count, state.reportItemCount == count,
                      state.firstVisibleNumber == offset + 1, state.lastVisibleNumber == offset + expected else { throw NativeScaleFailure.invalid("Disk page totals/size mismatch") }
                for (index, item) in state.visibleItems.enumerated() {
                    let number = offset + index
                    let digits = String(number), filename = "entry-" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits + ".bin"
                    let expectedPath = home.appendingPathComponent("Downloads").appendingPathComponent(filename).path
                    guard item.path == expectedPath, item.bytes == 64, item.canTrash == (number > 0) else { throw NativeScaleFailure.invalid("Unexpected/out-of-order duplicate row on page \(state.pageIndex)") }
                    if item.canTrash { processableSeen += 1 }
                }
                seen += state.visibleItems.count
                if state.pageIndex == 0 {
                    guard let first = state.visibleItems.first(where: \.canTrash) else { throw NativeScaleFailure.invalid("No actionable first-page candidate") }
                    state.toggle(first)
                    guard state.selected.count == 1 else { throw NativeScaleFailure.invalid("Current-page candidate could not be selected") }
                    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                    firstGeometry = try verifyGeometry(host: host, state: state)
                } else {
                    guard state.selected.isEmpty, state.selectedItems.isEmpty else { throw NativeScaleFailure.invalid("Selection survived a page change") }
                    clearedOnPageChange = true
                }
                pages.append(["index": state.pageIndex, "rows": state.visibleItems.count, "first": state.firstVisibleNumber, "last": state.lastVisibleNumber])
                if state.pageIndex + 1 == pageCount { break }
                state.nextPage()
                try wait("disk page \(state.pageIndex)", until: { !state.pageLoading })
                if let error = state.pageError { throw NativeScaleFailure.invalid(error) }
            }
            let lastGeometry = try verifyGeometry(host: host, state: state)
            guard seen == count, processableSeen == count - 1, state.pageIndex == pageCount - 1,
                  state.lastVisibleNumber == count, state.visibleItems.count == 1,
                  clearedOnPageChange, maximumVisible <= 200 else { throw NativeScaleFailure.invalid("Last-page/selection/bounded-array checks failed") }
            observations.append(["round": round, "scanSeconds": scanSeconds, "totalRoundSeconds": ProcessInfo.processInfo.systemUptime - roundStart,
                                 "totalItemCount": report.totalItemCount ?? -1, "processableItemCount": state.processableItemCount,
                                 "visitedFiles": report.visitedFiles, "truncated": report.truncated,
                                 "retainedReportArrayCount": report.items.count, "maximumVisibleItems": maximumVisible,
                                 "pagesVisited": pages, "pageCount": pageCount, "rowsAcrossPages": seen,
                                 "lastPageRows": state.visibleItems.count, "lastVisibleNumber": state.lastVisibleNumber,
                                 "selectionClearedOnPageChange": clearedOnPageChange,
                                 "coreScannerSampledPeakRSSBytes": report.peakResidentBytes ?? 0,
                                 "firstPageGeometry": firstGeometry, "lastPageGeometry": lastGeometry])
            print("PASS round \(round): real duplicate total=\(count), pages=\(pageCount), max UI rows=\(maximumVisible), scan=\(scanSeconds)s")
            if let reference = report.resultStore {
                state.suspendPresentation()
                try wait("release previous result store", until: { !FileManager.default.fileExists(atPath: reference.path) })
                state.resumePresentation()
            }
        }
        return observations
    }
    @MainActor private static func verifyGeometry(host: NSView, state: AppState) throws -> [String: Any] {
        host.layoutSubtreeIfNeeded()
        guard let root = NativeScaleProbe.frames["root"], let window = host.window else { throw NativeScaleFailure.invalid("Missing root/window geometry") }
        // NavigationSplitView extends its hosting view into the titlebar. The
        // requested content viewport is still 1080x730: exclude that titlebar
        // using AppKit's real contentLayoutRect, rather than accepting 762pt.
        let viewport = host.convert(window.contentLayoutRect, from: nil)
        guard abs(viewport.width - 1080) < 0.5, abs(viewport.height - 730) < 0.5 else { throw NativeScaleFailure.invalid("Unexpected visible content viewport: \(viewport)") }
        let bounds = CGRect(origin: .zero, size: viewport.size)
        let frames = NativeScaleProbe.frames.mapValues { $0.offsetBy(dx: -root.minX - viewport.minX, dy: -root.minY - viewport.minY) }
        for name in ["processableSummary", "list", "footer", "cleanup"] {
            guard let frame = frames[name], frame.width > 8, frame.height > 8,
                  frame.minX >= -0.5, frame.minY >= -0.5,
                  frame.maxX <= bounds.width + 0.5, frame.maxY <= bounds.height + 0.5 else { throw NativeScaleFailure.invalid("\(name) is outside the 1080x730 viewport") }
        }
        guard let list = frames["list"], let footer = frames["footer"], list.height >= 80, list.maxY <= footer.minY + 1 else { throw NativeScaleFailure.invalid("Candidate viewport is hidden or overlaps the fixed footer") }
        return ["frames": frames.mapValues { ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)] },
                "visibleContentWidth": Double(viewport.width), "visibleContentHeight": Double(viewport.height),
                "hostBoundsHeightIncludingTitlebar": Double(host.bounds.height),
                "visibleProcessableCount": state.processableItemCount, "selected": state.selectedItems.count,
                "cleanupEnabled": !state.busy && !state.selectedItems.isEmpty,
                "allRequiredMarkersInsideViewport": true]
    }
}
