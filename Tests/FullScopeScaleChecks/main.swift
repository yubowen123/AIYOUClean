import AppKit
import SwiftUI
import Darwin
import CleanRoomCore

@MainActor enum FullScopeFixture {
    static var home = URL(fileURLWithPath: "/generated-unconfigured-full-scope-home")
}
@MainActor struct FullScopeProbe: View {
    static var frames: [String: CGRect] = [:]
    let name: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.onAppear { Self.frames[name] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { Self.frames[name] = $0 }
                .onDisappear { Self.frames.removeValue(forKey: name) }
        }
    }
}
private enum FullScopeFailure: LocalizedError {
    case check(String), timeout(String)
    var errorDescription: String? { switch self { case .check(let text), .timeout(let text): return text } }
}

@main struct FullScopeScaleChecks {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 4 else { print("Expected output, owned home and nonce"); exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var result: [String: Any] = ["passed": false, "visionUsed": false, "windowSizePoints": [1080, 730]]
        do {
            let home = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: home.deletingLastPathComponent().appendingPathComponent("fixture-owner.json"))) as? [String: Any]
            guard marker?["kind"] as? String == "AIYOUClean.FullScopeScaleFixture", marker?["nonce"] as? String == CommandLine.arguments[3],
                  marker?["count"] as? Int == 12_001, marker?["bytes"] as? Int == 64,
                  marker?["largeBytes"] as? Int == 101_000_000, let digest = marker?["sha256"] as? String, digest.count == 64,
                  home.lastPathComponent == "home", home.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".perf-ui-fixtures",
                  !FileSafety.hasSymlinkComponent(home) else { throw FullScopeFailure.check("Only the owned canonical project fixture may be scanned") }
            let large = home.appendingPathComponent("Custom/unique-large.bin")
            var metadata = stat()
            guard lstat(large.path, &metadata) == 0, metadata.st_size == 101_000_000,
                  metadata.st_mode & 0o777 == 0o200, geteuid() != 0,
                  !FileManager.default.isReadableFile(atPath: large.path) else { throw FullScopeFailure.check("Unique sparse file must be unreadable to prove its content is not hashed") }
            FullScopeFixture.home = home
            NSApplication.shared.setActivationPolicy(.prohibited)
            result["measurement"] = try measure(home: home, digest: digest)
            result["uniqueSparseContentReadDeniedByPOSIX"] = true
            result["passed"] = true
        } catch { result["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { print("Cannot write full-scope measurement: \(error)"); exit(2) }
        if result["passed"] as? Bool != true { print("FAIL \(result["error"] ?? "Full-scope checks failed")"); exit(1) }
    }
    @MainActor private static func measure(home: URL, digest: String) throws -> [String: Any] {
        let state = SmartCareViewState()
        let defaultIsFullDisk = state.scanScope == .allLocalDisks
        guard defaultIsFullDisk else { throw FullScopeFailure.check("GUI default is not allLocalDisks") }
        state.setScanScope(.selectedFolders); state.useOwnedFixtureRoot(home)
        guard state.scanScope == .selectedFolders, state.roots.map(\.path) == [home.path], state.canStartScan else { throw FullScopeFailure.check("Owned selected-folder setup failed") }
        let root = HStack(spacing: 0) {
            Color(red: 0.07, green: 0.075, blue: 0.13).frame(width: 235)
            SmartCareView(measurementState: state).background(Color(red: 0.06, green: 0.07, blue: 0.12))
        }.preferredColorScheme(.dark).background(FullScopeProbe(name: "root"))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "AIYOUClean真实全范围引擎夹具（仅假home，不清理）"; window.contentView = host
        window.setContentSize(NSSize(width: 1080, height: 730)); window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        var maxVisible = 0
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.035)); maxVisible = max(maxVisible, state.pageItems.count) }
        func wait(_ name: String, until predicate: () -> Bool) throws {
            while !predicate() {
                if ProcessInfo.processInfo.systemUptime >= deadline { throw FullScopeFailure.timeout("180s watchdog: " + name) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02)); maxVisible = max(maxVisible, state.pageItems.count)
            }
            settle()
        }
        defer {
            state.cancel(); state.stopOnDisappear(); window.orderOut(nil); window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)); settle()
        for _ in 0..<3 {
            let actual = window.contentLayoutRect.size
            if abs(actual.width - 1080) < 0.5 && abs(actual.height - 730) < 0.5 { break }
            var frame = window.frame; frame.size.width += 1080 - actual.width; frame.size.height += 730 - actual.height
            window.setFrame(frame, display: false); settle()
        }
        let scanStart = ProcessInfo.processInfo.systemUptime
        state.scan()
        guard state.phase != nil else { throw FullScopeFailure.check("Real SmartCareViewState.scan did not start") }
        try wait("real SmartCare/FullDisk engine and first SQL page", until: { !state.busy })
        guard let report = state.report, let coverage = report.diskCoverage else { throw FullScopeFailure.check("No FullDisk coverage; legacy Scanner path is not a substitute") }
        guard !report.invalidated, !report.cancelled, coverage.roots == [home.path], coverage.regularFiles == 12_002,
              !coverage.incomplete, !coverage.cancelled, coverage.inaccessibleEntries == 0,
              coverage.skippedCloudEntries == 0, coverage.skippedLinkEntries == 0, coverage.excludedEntries == 0,
              coverage.logicalBytes == 101_000_000 + 12_001 * 64,
              report.totalItemCount == 12_001, report.totalProcessableBytes == 101_000_000 + 12_000 * 64,
              report.items.count <= 200, state.resultMode == .processable, state.pageItemCount == 12_001 else {
            throw FullScopeFailure.check("Full-scope coverage/candidate totals failed: roots=\(coverage.roots), files=\(coverage.regularFiles), incomplete=\(coverage.incomplete), candidates=\(report.totalItemCount), notes=\(coverage.notes), warnings=\(report.warnings)")
        }
        guard let largeModule = report.modules.first(where: { $0.kind == .largeFiles }), largeModule.count == 1, largeModule.processableCount == 1, !largeModule.incomplete,
              let duplicatesModule = report.modules.first(where: { $0.kind == .duplicates }), duplicatesModule.count == 12_001, duplicatesModule.processableCount == 12_000, !duplicatesModule.incomplete,
              !report.modules.contains(where: { $0.kind == .applications }) else { throw FullScopeFailure.check("New full-scope large/duplicate module proof failed or selected mode expanded into global applications") }
        let scanSeconds = ProcessInfo.processInfo.systemUptime - scanStart
        if report.modules.allSatisfy({ !$0.incomplete }) && report.incomplete {
            throw FullScopeFailure.check("Structured complete modules were mislabeled as an incomplete report")
        }
        guard let processRef = report.resultStore, let readOnlyRef = report.readOnlyStore, let issueRef = coverage.issueStore else { throw FullScopeFailure.check("Missing one of the three result-store references") }
        let references = [processRef, readOnlyRef, issueRef]
        guard references[0].path != references[1].path, references[0].path != references[2].path, references[1].path != references[2].path else { throw FullScopeFailure.check("Expected distinct owned result stores") }
        let actionableStats = try ScanResultStore(reference: processRef).statistics()
        let readOnlyStats = try ScanResultStore(reference: readOnlyRef).statistics()
        let issueStats = try ScanResultStore(reference: issueRef).statistics()
        guard actionableStats.totalCount == 12_001, actionableStats.processableCount == 12_001,
              readOnlyStats.totalCount == report.readOnlyStoredCount, readOnlyStats.processableCount == 0,
              issueStats.totalCount == coverage.issueCount, issueStats.totalCount == 0, issueStats.processableCount == 0 else { throw FullScopeFailure.check("Report counts disagree with the actual three SQLite stores") }
        let keeper = home.appendingPathComponent("Custom/copy-00003.bin")
        guard let keeperIdentity = FileSafety.identity(keeper) else { throw FullScopeFailure.check("Generated duplicate keeper disappeared") }
        let order = [("Custom", 3), ("Desktop", 1), ("Documents", 0), ("Movies", 2)]
        var directoryCursor = 0, nextIndex = 3
        func nextExpectedDuplicate() -> String? {
            while directoryCursor < order.count {
                let directory = order[directoryCursor].0, index = nextIndex; nextIndex += 4
                if index >= 12_001 {
                    directoryCursor += 1
                    if directoryCursor < order.count { nextIndex = order[directoryCursor].1 }
                    continue
                }
                if directory == "Custom" && index == 3 { continue }
                let digits = String(index), filename = "copy-" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits + ".bin"
                return home.appendingPathComponent(directory).appendingPathComponent(filename).path
            }
            return nil
        }
        var duplicatesSeen = 0, largeSeen = 0, rowsSeen = 0
        var byDirectory = ["Documents": 0, "Desktop": 0, "Movies": 0, "Custom": 0]
        var pages: [[String: Any]] = [], firstGeometry: [String: Any] = [:]
        var selectionCleared = false
        while true {
            let offset = state.page * state.pageSize, expectedRows = min(200, 12_001 - offset)
            guard state.pageItems.count == expectedRows, state.pageItemCount == 12_001, state.pageError == nil else { throw FullScopeFailure.check("Processable page is incomplete") }
            for item in state.pageItems {
                guard item.canTrash, item.scopeRoot == home.path else { throw FullScopeFailure.check("Unexpected non-actionable/out-of-scope candidate") }
                if item.bytes == 101_000_000 {
                    guard item.path == home.appendingPathComponent("Custom/unique-large.bin").path, item.group == nil else { throw FullScopeFailure.check("Unique large-file result is wrong") }
                    largeSeen += 1
                } else {
                    guard item.bytes == 64, item.group == digest, item.retainedPath == keeper.path,
                          item.retainedIdentity == keeperIdentity, item.path == nextExpectedDuplicate() else { throw FullScopeFailure.check("Cross-directory duplicate membership/order/retained identity failed") }
                    let directory = URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent
                    guard byDirectory[directory] != nil else { throw FullScopeFailure.check("Duplicate escaped the four owned folders") }
                    byDirectory[directory, default: 0] += 1; duplicatesSeen += 1
                }
            }
            rowsSeen += state.pageItems.count
            if state.page == 0 {
                guard let item = state.pageItems.first else { throw FullScopeFailure.check("No first page") }
                state.toggle(item); settle(); firstGeometry = try geometry(host: host, state: state)
                guard state.selected.count == 1 else { throw FullScopeFailure.check("Current-page selection did not work") }
            } else {
                guard state.selected.isEmpty, state.selectedItems.isEmpty else { throw FullScopeFailure.check("Selection survived pagination") }
                selectionCleared = true
            }
            pages.append(["page": state.page, "rows": state.pageItems.count])
            if state.page + 1 == state.pageCount { break }
            state.nextPage(); try wait("processable disk page", until: { !state.pageLoading })
        }
        let lastGeometry = try geometry(host: host, state: state)
        guard rowsSeen == 12_001, duplicatesSeen == 12_000, largeSeen == 1,
              byDirectory == ["Documents": 3001, "Desktop": 3000, "Movies": 3000, "Custom": 2999],
              nextExpectedDuplicate() == nil, state.pageCount == 61, state.page == 60, state.pageItems.count == 1,
              selectionCleared, maxVisible <= 200 else { throw FullScopeFailure.check("All-page/cross-folder completeness checks failed") }
        var keeperCount = 0, statusCount = 0
        let allowedStatusPaths = ["/usr/sbin/spctl", "/usr/bin/csrutil", "/usr/bin/fdesetup", "/usr/libexec/ApplicationFirewall/socketfilterfw"]
        try ScanResultStore(reference: readOnlyRef).forEachItem { item in
            guard !item.canTrash else { throw FullScopeFailure.check("Read-only store exposes a cleanup candidate") }
            if item.group == digest {
                guard item.path == keeper.path, item.bytes == 64, item.retainedPath == keeper.path else { throw FullScopeFailure.check("Read-only duplicate original is wrong") }
                keeperCount += 1
            } else {
                guard item.category == "安全配置状态", allowedStatusPaths.contains(item.path) else { throw FullScopeFailure.check("Read-only output escaped the owned files/read-only command allowlist") }
                statusCount += 1 // Do not assert command exit/success/status text.
            }
        }
        guard keeperCount == 1 else { throw FullScopeFailure.check("Duplicate original was lost or duplicated") }
        let rememberedCandidate = state.pageItems[0]
        state.toggle(rememberedCandidate); state.setResultMode(.readOnly)
        try wait("real read-only page", until: { !state.pageLoading })
        guard state.pageItemCount == readOnlyStats.totalCount else { throw FullScopeFailure.check("Read-only UI count differs from SQL") }
        state.toggle(rememberedCandidate); state.selectPage(); state.requestTrash(); settle()
        guard state.selected.isEmpty, state.selectedItems.isEmpty, state.confirmation == nil, state.pageItems.allSatisfy({ !$0.canTrash }) else { throw FullScopeFailure.check("Read-only mode permits selection/cleanup") }
        let readOnlyGeometry = try geometry(host: host, state: state)
        state.setResultMode(.issues); try wait("real coverage-issue page", until: { !state.pageLoading })
        state.toggle(rememberedCandidate); state.selectPage(); state.requestTrash(); settle()
        guard state.pageItemCount == issueStats.totalCount, state.pageItems.isEmpty, state.selected.isEmpty, state.selectedItems.isEmpty, state.confirmation == nil else { throw FullScopeFailure.check("Issue mode permits cleanup or shows inaccurate totals") }
        let issueGeometry = try geometry(host: host, state: state)
        state.stopOnDisappear()
        try wait("delete all three owned stores", until: { references.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } })
        print("PASS real FullDisk SmartCare: 12002 files, 12001 candidates, 61 pages, three stores released")
        return ["defaultScopeWasAllLocalDisks": defaultIsFullDisk, "measuredScope": "selectedFolders", "coverageRoots": coverage.roots,
                "coverageRegularFiles": coverage.regularFiles, "coverageVisitedEntries": coverage.visitedEntries, "coverageLogicalBytes": coverage.logicalBytes,
                "coverageIncomplete": coverage.incomplete, "coverageIssueCount": coverage.issueCount, "coverageInaccessible": coverage.inaccessibleEntries,
                "scanSeconds": scanSeconds, "totalItemCount": report.totalItemCount, "totalProcessableBytes": report.totalProcessableBytes,
                "duplicateCopies": duplicatesSeen, "duplicateOriginals": keeperCount, "uniqueLargeFiles": largeSeen, "duplicatesByDirectory": byDirectory,
                "pageCount": 61, "pages": pages, "rowsAcrossPages": rowsSeen, "lastPageRows": 1, "maximumVisibleItems": maxVisible,
                "selectionClearedOnPageChange": selectionCleared, "reportPreviewCount": report.items.count,
                "readOnlySQLCount": readOnlyStats.totalCount, "readOnlyUICount": readOnlyStats.totalCount, "readOnlyStatusRecords": statusCount,
                "issueSQLCount": issueStats.totalCount, "issueUICount": issueStats.totalCount, "statusCommandSuccessAsserted": false,
                "threeOwnedReferencesDeleted": true, "firstPageGeometry": firstGeometry, "lastPageGeometry": lastGeometry,
                "readOnlyGeometry": readOnlyGeometry, "issueGeometry": issueGeometry,
                "structuredDiskModulesComplete": !largeModule.incomplete && !duplicatesModule.incomplete, "overallReportIncomplete": report.incomplete, "securityModuleWarnings": report.modules.first(where: { $0.kind == .protection })?.warnings ?? []]
    }
    @MainActor private static func geometry(host: NSView, state: SmartCareViewState) throws -> [String: Any] {
        guard let root = FullScopeProbe.frames["root"], let window = host.window else { throw FullScopeFailure.check("Missing root geometry") }
        let viewport = host.convert(window.contentLayoutRect, from: nil)
        guard abs(viewport.width - 1080) < 0.5, abs(viewport.height - 730) < 0.5 else { throw FullScopeFailure.check("Viewport is not exactly 1080x730: \(viewport)") }
        let frames = FullScopeProbe.frames.mapValues { $0.offsetBy(dx: -root.minX - viewport.minX, dy: -root.minY - viewport.minY) }
        let names = ["summary", "modes", "list", "footer"] + (state.resultMode == .processable ? ["cleanup"] : [])
        for name in names {
            guard let rect = frames[name], rect.width > 8, rect.height > 8, rect.minX >= -0.5, rect.minY >= -0.5,
                  rect.maxX <= 1080.5, rect.maxY <= 730.5 else { throw FullScopeFailure.check("\(name) outside the real viewport") }
        }
        guard let list = frames["list"], let footer = frames["footer"], list.height >= 80, list.maxY <= footer.minY + 1 else { throw FullScopeFailure.check("List/geometry overlaps fixed footer") }
        if state.resultMode != .processable, frames["cleanup"] != nil { throw FullScopeFailure.check("Read-only/issue view still renders a cleanup button") }
        return ["mode": state.resultMode.rawValue, "visibleWidth": Double(viewport.width), "visibleHeight": Double(viewport.height),
                "allRequiredMarkersVisible": true, "frames": frames.mapValues { ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)] }]
    }
}
