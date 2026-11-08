import AppKit
import SwiftUI
import Foundation
import CleanRoomCore

/// Pauses only a UI progress callback from a real worker. It never fabricates
/// scan results/counts. The watchdog makes a broken harness fail without hanging.
final class LifecycleWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holding = false
    private var entered = false
    private var expired = false
    func arm() { condition.lock(); holding = true; entered = false; expired = false; condition.unlock() }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        guard holding else { return }
        entered = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(30)
        while holding {
            if !condition.wait(until: deadline) { expired = true; holding = false; break }
        }
    }
    func release() { condition.lock(); holding = false; condition.broadcast(); condition.unlock() }
    var reached: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return expired }
}
enum LifecycleFixture {
    @MainActor static var home = URL(fileURLWithPath: "/unconfigured-owned-lifecycle-fixture")
    static let gate = LifecycleWorkerGate()
}
@MainActor struct TaskLifecycleProbe: View {
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
private enum LifecycleFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
private final class LifecycleCounter: @unchecked Sendable {
    private let lock = NSLock(); private var number = 0
    func increment() { lock.lock(); number += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return number }
}

@main struct TaskLifecycleChecks {
    @MainActor static func main() {
        var output: URL?
        var result: [String: Any] = ["passed": false, "scannerStubbed": false, "userAppControlled": false]
        do {
            guard CommandLine.arguments.count == 4 else { throw LifecycleFailure.invalid("Expected output, owned home, nonce") }
            output = URL(fileURLWithPath: CommandLine.arguments[1])
            let home = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let fixture = home.deletingLastPathComponent()
            let expectedParent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-fixtures").standardizedFileURL
            let prefix = "task-lifecycle-"
            guard fixture.deletingLastPathComponent() == expectedParent, fixture.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(fixture.lastPathComponent.dropFirst(prefix.count))) != nil,
                  home.lastPathComponent == "home", !FileSafety.hasSymlinkComponent(home) else { throw LifecycleFailure.invalid("Only the owned generated fixture may be scanned") }
            let markerURL = fixture.appendingPathComponent("fixture-owner.json")
            let markerData = try Data(contentsOf: markerURL)
            guard markerData.count < 4096,
                  let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any],
                  marker["kind"] as? String == "AIYOUClean.TaskLifecycleFixture",
                  marker["nonce"] as? String == CommandLine.arguments[3], marker["duplicates"] as? Int == 2602,
                  marker["largeBytes"] as? Int64 == 100_000_123 else { throw LifecycleFailure.invalid("Fixture ownership marker does not match") }
            LifecycleFixture.home = home
            NSApplication.shared.setActivationPolicy(.prohibited)
            result["ticketChecks"] = try ticketChecks()
            result["uiChecks"] = try uiChecks(home: home)
            result["passed"] = true
        } catch { result["error"] = error.localizedDescription; print("FAIL \(error.localizedDescription)") }
        LifecycleFixture.gate.release()
        if let output {
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
            catch { print("FAIL cannot write lifecycle evidence: \(error)"); exit(2) }
        }
        if result["passed"] as? Bool != true { exit(1) }
        print("PASS production UI lifecycle, actual owned-directory scans, global ticket exclusion and worker acknowledgement")
    }
    @MainActor private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw LifecycleFailure.invalid(message) }
    }
    @MainActor private static func settle(_ seconds: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor private static func wait(_ description: String, seconds: TimeInterval = 30, until predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw LifecycleFailure.invalid("Timed out: " + description) }
            settle(0.015)
        }
    }
    @MainActor private static func ticketChecks() throws -> [String: Bool] {
        let center = DetectionTaskCenter()
        var cancellations = 0
        guard let first = center.begin("fixture A", destination: .smartCare, cancel: { cancellations += 1 }) else { throw LifecycleFailure.invalid("First ticket refused") }
        center.update(first, count: 41, path: "generated path", phase: "hashing")
        let before = center.active
        try require(center.begin("fixture blocked", destination: .privacy, cancel: nil) == nil, "Second ticket was accepted")
        try require(center.active?.id == first && center.active?.count == before?.count && center.active?.phase == "hashing", "Refusal changed active progress/phase")
        center.cancelActive(); center.cancelActive()
        try require(center.isBusy && center.active?.isCancelling == true && cancellations == 1, "Cancel must retain the ticket and be idempotent")
        center.finish(UUID())
        try require(center.active?.id == first, "Unrelated finish released active ticket")
        center.finish(first)
        guard let second = center.begin("fixture B", destination: .maintenance, cancel: nil) else { throw LifecycleFailure.invalid("Ticket remained locked after acknowledgement") }
        center.update(second, count: 9, path: "second", phase: "waiting")
        center.finish(first); center.update(first, count: 999, path: "stale", phase: "stale")
        center.markCancelling(first); center.cancelActive()
        try require(center.active?.id == second && center.active?.count == 9 && center.active?.phase == "waiting" && center.active?.canCancel == false && center.active?.isCancelling == false, "Stale/uncancellable operation changed a newer ticket")
        center.finish(second); center.dismissFinished()
        try require(!center.isBusy && center.lastFinished == nil, "Finished dismissal retained busy state")
        let registry = FeatureStateRegistry(tasks: center)
        let firstObject: NSObject = registry.retain("fixture-identity") { NSObject() }
        let sameObject: NSObject = registry.retain("fixture-identity") { NSObject() }
        try require(firstObject === sameObject && registry.tasks === center, "Registry did not preserve controller/center identity")
        return ["atomicBegin": true, "cancelWaitsForAcknowledgement": true, "staleFinishAndUpdateIgnored": true,
                "uncancellableCannotBeReleasedByCancel": true, "registryIdentity": true]
    }
    @MainActor private static func uiChecks(home: URL) throws -> [String: Any] {
        let center = DetectionTaskCenter()
        let app = AppState(taskCenter: center), registry = app.featureStates
        let smart: SmartCareViewState = registry.retain("smartCare") { SmartCareViewState(taskCenter: center) }
        let lens: SpaceLensViewModel = registry.retain("spaceLens") { SpaceLensViewModel(taskCenter: center) }
        let operations: OperationsState = registry.retain("operations") { OperationsState(taskCenter: center) }
        let advanced: AdvancedCleanupState = registry.retain("advancedCleanup") { AdvancedCleanupState(taskCenter: center) }
        let privacyService = BrowserPrivacyService(storageRoot: home.appendingPathComponent("FixturePrivacyBackups"), browserRunning: { _ in false })
        let privacy: BrowserPrivacyViewModel = registry.retain("privacy") { BrowserPrivacyViewModel(taskCenter: center, service: privacyService, home: home) }
        let probeCalls = LifecycleCounter()
        let status = try JSONDecoder().decode(ClamAVEngineStatus.self, from: Data("""
        {"version":"owned fixture, no engine execution","databaseDirectory":"\(home.path)","databaseFiles":[],"databaseState":"missing","databaseVerified":false,"warnings":[]}
        """.utf8))
        let malware: MalwarePanelState = registry.retain("malware") { MalwarePanelState(taskCenter: center, probe: { probeCalls.increment(); return MalwarePanelProbe(engine: status, records: [], error: nil) }) }
        let host = NSHostingView(rootView: MainView().environmentObject(app).preferredColorScheme(.dark).background(TaskLifecycleProbe(name: "root")))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "AIYOUClean隔离生命周期夹具（只扫描生成目录）"; window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
        var references: [ScanResultReference] = []
        var lensReferences: [ScanResultReference] = []
        defer {
            LifecycleFixture.gate.release(); center.cancelActive()
            try? wait("worker cleanup", seconds: 20, until: { !center.isBusy })
            smart.releaseReport(); lens.clearReport(); app.setRoots([])
            try? wait("owned result cleanup", seconds: 10, until: { (references + lensReferences).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } })
            window.orderOut(nil); window.close()
        }
        settle(0.2); host.layoutSubtreeIfNeeded()
        // Match the actual content viewport after NavigationSplitView configures
        // the titlebar; no desktop screen or user window is captured.
        for _ in 0..<3 {
            let actual = window.contentLayoutRect.size
            if abs(actual.width - 1080) < 0.5 && abs(actual.height - 730) < 0.5 { break }
            var frame = window.frame; frame.size.width += 1080 - actual.width; frame.size.height += 730 - actual.height
            window.setFrame(frame, display: false); settle(0.05)
        }
        let downloads = home.appendingPathComponent("Downloads")
        // A real standard scan must finish and retain its report while hidden.
        app.destination = .scan(.downloads); app.setRoots([downloads]); settle()
        LifecycleFixture.gate.arm(); app.scan()
        guard let standardID = center.active?.id else { throw LifecycleFailure.invalid("Real standard scan did not start") }
        try wait("standard real progress callback", until: { LifecycleFixture.gate.reached })
        app.suspendPresentation(); app.destination = .dashboard; settle()
        app.destination = .maintenance; settle(); app.destination = .scan(.spaceLens); settle()
        try require(center.active?.id == standardID && app.isScanning, "Standard scan was cancelled by navigation/hide")
        try wait("standard hidden progress pump", until: { (center.active?.count ?? 0) > 0 })
        let standardGeometry = try geometry(host: host, window: window, cancel: true)
        LifecycleFixture.gate.release()
        try wait("standard background completion", until: { !center.isBusy && !app.isScanning })
        app.destination = .scan(.downloads); app.resumePresentation()
        try wait("standard restored page", until: { !app.pageLoading && app.report != nil })
        // Downloads intentionally lists immediate children (three groups and
        // one large file); its nested size walk still examines the real files.
        try require(app.reportItemCount == 4 && app.visibleItems.count == 4 && app.report?.truncated == false, "Standard hidden result was lost or truncated: total=\(app.reportItemCount), visible=\(app.visibleItems.count), pageLoading=\(app.pageLoading), truncated=\(String(describing: app.report?.truncated)), stop=\(String(describing: app.report?.stopReason)), error=\(app.pageError ?? "none"), warnings=\(app.report?.warnings.joined(separator: " | ") ?? "none")")
        guard let standardReference = app.latestReport?.resultStore else { throw LifecycleFailure.invalid("Missing standard result index") }
        references.append(standardReference)

        // Seed a real space result so a rejected restart must preserve actual
        // scope/result metadata, rather than merely preserving empty defaults.
        app.destination = .scan(.spaceLens); settle(); LifecycleFixture.gate.arm(); lens.start(downloads, replaceBase: true)
        guard let spaceID = center.active?.id else { throw LifecycleFailure.invalid("Real space scan did not start") }
        try wait("space real progress callback", until: { LifecycleFixture.gate.reached })
        lens.release(); app.destination = .dashboard; settle()
        try require(center.active?.id == spaceID && lens.busy, "Space scan stopped when its view disappeared")
        LifecycleFixture.gate.release(); try wait("space background completion", until: { !center.isBusy && !lens.busy })
        guard let spaceReference = lens.report?.resultStore else { throw LifecycleFailure.invalid("Missing retained space result") }
        lensReferences.append(spaceReference)
        let savedSpaceRoot = lens.currentRoot, savedSpaceCount = lens.totalCount
        try require(savedSpaceCount == 4, "Space result lost fixture child directories/large file")

        smart.includeApplications = false; smart.roots = [home]; smart.scanScope = .selectedFolders
        app.destination = .smartCare; settle(); LifecycleFixture.gate.arm(); smart.scan()
        guard let smartID = center.active?.id else { throw LifecycleFailure.invalid("Real SmartCare scan did not start") }
        smart.stopOnDisappear(); app.suspendPresentation()
        var navigated = 0
        for destination: Destination in [.dashboard, .scan(.downloads), .scan(.spaceLens)] {
            app.destination = destination; settle(); navigated += 1
            let same: SmartCareViewState = registry.retain("smartCare") { SmartCareViewState(taskCenter: center) }
            try require(same === smart && center.active?.id == smartID && smart.phase != nil, "Navigation replaced the SmartCare controller/ticket")
        }
        try wait("SmartCare actual progress callback", until: { LifecycleFixture.gate.reached })
        try wait("SmartCare center progress while hidden", until: { (center.active?.count ?? 0) > 0 })
        let hiddenProgress = center.active?.count ?? 0
        let smartGeometry = try geometry(host: host, window: window, cancel: true)
        app.resumePresentation(); app.destination = .scan(.downloads)
        let rootScope = app.roots, rootProgress = app.progressCount
        app.scan(); app.message = nil
        try require(!app.isScanning && app.latestReport?.resultStore == standardReference && app.roots == rootScope && app.progressCount == rootProgress && center.active?.id == smartID, "Refused standard scan reset prior scope/report/progress")
        lens.start(home, replaceBase: true); lens.message = nil
        try require(!lens.busy && lens.currentRoot == savedSpaceRoot && lens.report?.resultStore == spaceReference && lens.totalCount == savedSpaceCount && center.active?.id == smartID, "Refused space scan reset prior scope/report")
        let advancedCalls = LifecycleCounter(); advanced.selected = ["owned-selection"]
        advanced.start("fixture rejected advanced", clearResults: true) { _, _ in advancedCalls.increment(); return .failure("must not execute") }; advanced.message = nil
        privacy.selected = ["owned-selection"]; privacy.scan(); privacy.message = nil
        malware.loadIfNeeded(); malware.refresh(); malware.message = nil
        operations.start("fixture rejected maintenance") { advancedCalls.increment(); return "must not execute" }; operations.message = nil
        try require(!advanced.busy && advanced.selected == ["owned-selection"] && advancedCalls.value == 0 && !privacy.busy && privacy.selected == ["owned-selection"] && !malware.busy && !malware.loaded && probeCalls.value == 0 && !operations.busy, "Another feature started or reset state while SmartCare held the ticket")
        advanced.selected = []; privacy.selected = []
        LifecycleFixture.gate.release()
        try wait("SmartCare background completion", seconds: 60, until: { !center.isBusy && smart.phase == nil })
        try require(!LifecycleFixture.gate.timedOut && smart.report != nil && smart.pageItems.isEmpty, "Hidden SmartCare result missing or retained a hidden page")
        guard let report = smart.report, let reference = report.resultStore else { throw LifecycleFailure.invalid("Missing SmartCare result index") }
        references += [reference, report.readOnlyStore, report.diskCoverage?.issueStore].compactMap { $0 }
        let store = try ScanResultStore(reference: reference)
        let statistics = try store.statistics()
        try require(statistics.totalCount == 2602 && statistics.processableCount == 2602 && report.totalItemCount == 2602 && report.diskCoverage?.regularFiles == 2603 && report.diskCoverage?.roots == [home.path] && report.diskCoverage?.incomplete == false, "SmartCare did not process the complete owned fixture")
        let expectedKeeper = downloads.appendingPathComponent("group-0/copy-00000.bin")
        let keeperIdentity = FileSafety.identity(expectedKeeper)
        var copies = 0, large = 0
        try store.forEachItem { item in
            try require(FileSafety.contains(home.path, item.path), "Result escaped the owned fixture")
            if let keeper = item.retainedPath {
                copies += 1
                try require(keeper == expectedKeeper.path && item.retainedIdentity == keeperIdentity && item.path != keeper, "Duplicate keeper identity/path mismatch")
            } else if item.bytes == 100_000_123 { large += 1 }
        }
        try require(copies == 2601 && large == 1 && keeperIdentity != nil, "Duplicate keeper/large file counts mismatch")
        let lastPage = try store.page(offset: 2600, limit: 200)
        try require(lastPage.items.count == 2 && lastPage.filteredCount == 2602, "Last disk page lost candidates")
        app.destination = .smartCare; app.resumePresentation(); smart.resume()
        try wait("SmartCare returned first page", until: { !smart.pageLoading && smart.pageItems.count == 200 })
        try require(smart.report?.resultStore == reference && (center.lastFinished?.count ?? 0) > hiddenProgress, "Returned SmartCare result/progress was reset")
        let finishedGeometry = try geometry(host: host, window: window, cancel: false)

        // Hold an actual second SmartCare worker at its callback so cancellation
        // acknowledgement is deterministic, not a race against a fast fixture.
        LifecycleFixture.gate.arm(); smart.scan()
        guard let cancellingID = center.active?.id else { throw LifecycleFailure.invalid("Second real SmartCare did not start") }
        try wait("cancel scan actual callback", until: { LifecycleFixture.gate.reached })
        smart.stopOnDisappear(); app.destination = .dashboard; settle()
        center.cancelActive()
        try require(center.isBusy && center.active?.id == cancellingID && center.active?.isCancelling == true && smart.phase != nil, "Cancel released the ticket before worker acknowledgement")
        try require(center.begin("too early", destination: .privacy, cancel: nil) == nil, "New job began before cancellation acknowledgement")
        center.finish(smartID)
        try require(center.active?.id == cancellingID, "Old finish released the cancelling worker")
        let cancellingGeometry = try geometry(host: host, window: window, cancel: true)
        LifecycleFixture.gate.release(); try wait("cancel acknowledgement", until: { !center.isBusy && smart.phase == nil })
        guard let partial = smart.report else { throw LifecycleFailure.invalid("Cancelled background report disappeared") }
        references += [partial.resultStore, partial.readOnlyStore, partial.diskCoverage?.issueStore].compactMap { $0 }
        try require(partial.cancelled && partial.incomplete && !partial.invalidated, "Cancelled report not marked partial/cancelled")
        app.destination = .smartCare; smart.resume(); settle()
        try require(smart.report?.cancelled == true && !center.isBusy, "Cancelled report could not be revisited")

        // No real maintenance: use the production start/finish lifecycle with a
        // generated worker. It is explicitly uncancellable until it returns.
        LifecycleFixture.gate.arm(); operations.start("generated maintenance worker") { LifecycleFixture.gate.wait(); return "owned fixture worker returned" }
        guard let maintenanceID = center.active?.id else { throw LifecycleFailure.invalid("Fake maintenance did not begin") }
        try wait("maintenance fake worker", until: { LifecycleFixture.gate.reached })
        app.destination = .maintenance; settle(); app.destination = .dashboard; settle(); center.cancelActive()
        try require(center.active?.id == maintenanceID && center.active?.canCancel == false && center.active?.isCancelling == false && operations.busy, "Uncancellable maintenance released/reset on navigation/cancel")
        let uncancellableGeometry = try geometry(host: host, window: window, cancel: false, finished: false)
        LifecycleFixture.gate.release(); try wait("maintenance fake acknowledgement", until: { !center.isBusy && !operations.busy })
        app.destination = .maintenance; settle()
        let sameOperations: OperationsState = registry.retain("operations") { OperationsState(taskCenter: center) }
        try require(sameOperations === operations && operations.result == "owned fixture worker returned", "Maintenance controller/result not retained")
        try require(!DetectionTaskCenter.shared.isBusy && !LifecycleFixture.gate.timedOut, "Fixture polluted the shared center or timed out a gate")
        return ["navigationPagesWhileActive": navigated, "hiddenProgressCount": hiddenProgress,
                "smartCareCandidates": statistics.totalCount, "duplicateCopies": copies, "largeFiles": large,
                "lastDiskPageRows": lastPage.items.count, "uiPageRows": 200,
                "standardReportSurvivesNavigation": true, "spaceReportSurvivesNavigation": true,
                "controllerIdentityRetained": true, "allOtherFeatureStartsRefused": true,
                "cancelWaitsForWorkerAcknowledgement": true, "cancelledReportRevisitable": true,
                "uncancellableMaintenanceProtected": true,
                "geometry": ["standard": standardGeometry, "smartCare": smartGeometry, "finished": finishedGeometry,
                             "cancelling": cancellingGeometry, "uncancellable": uncancellableGeometry]]
    }
    @MainActor private static func geometry(host: NSView, window: NSWindow, cancel: Bool, finished: Bool = true) throws -> [String: Any] {
        settle(0.05); host.layoutSubtreeIfNeeded(); settle(0.025)
        guard let root = TaskLifecycleProbe.frames["root"] else { throw LifecycleFailure.invalid("Missing offscreen root geometry") }
        let viewport = host.convert(window.contentLayoutRect, from: nil)
        let bounds = CGRect(origin: .zero, size: viewport.size)
        let frames = TaskLifecycleProbe.frames.mapValues { $0.offsetBy(dx: -root.minX - viewport.minX, dy: -root.minY - viewport.minY) }
        var required = ["banner", "sidebar"]
        required.append(cancel || !finished ? "return" : "result")
        if cancel { required.append("cancel") }
        for name in required {
            guard let frame = frames[name], frame.width > 8, frame.height > 8,
                  frame.minX >= -1, frame.minY >= -1, frame.maxX <= bounds.maxX + 1, frame.maxY <= bounds.maxY + 1 else {
                throw LifecycleFailure.invalid("Global \(name) outside 1080×730 content viewport: \(String(describing: frames[name])); viewport=\(viewport)")
            }
        }
        if !cancel {
            try require(frames["cancel"] == nil, "An uncancellable/finished task still presents a cancel control")
            if finished { try require(frames["return"] == nil, "A finished task retained the running-task return control") }
        }
        return ["contentWidth": Double(viewport.width), "contentHeight": Double(viewport.height),
                "requiredVisible": required, "frames": frames.mapValues { ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)] }]
    }
}
