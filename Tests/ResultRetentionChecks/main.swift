import AppKit
import SwiftUI
import Foundation
import CleanRoomCore

// This native harness links real release Core and temporary copies of the real
// three UI controllers. Only access control and read-only telemetry are changed.
// Every mutation below targets a nonce-owned project fixture through injected
// real TrashManager / TrashInspector instances, never the user's home or Trash.
struct RetentionSnapshot: Sendable {
    let host = "owned retention fixture", os = "fixture"
    let totalDisk: Int64 = 1_000_000, availableDisk: Int64 = 500_000
    let totalMemory: UInt64 = 1_000_000
    let processors = 1, uptime: TimeInterval = 0
    let loadAverage = "fixture", battery = "fixture"
}
enum RetentionFixture { static func snapshot() -> RetentionSnapshot { RetentionSnapshot() } }
private struct RetentionFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@MainActor private final class RetentionHarness {
    let root: URL, output: URL, registry: URL
    var references: [ScanResultReference] = []
    var evidence: [[String: Any]] = []
    var assertions = 0
    init(root: URL, output: URL, registry: URL) { self.root = root; self.output = output; self.registry = registry }
    func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw RetentionFailure(text: message) }
    }
    func spin(_ label: String, until predicate: () -> Bool) throws {
        let end = Date().addingTimeInterval(30)
        while !predicate() {
            if Date() > end { throw RetentionFailure(text: "Timed out: " + label) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    func track(_ reference: ScanResultReference?) throws {
        guard let reference, !references.contains(reference) else { return }
        references.append(reference)
        try JSONEncoder().encode(references).write(to: registry, options: .atomic)
    }
    func cleanup() -> [String] {
        var errors: [String] = []
        for reference in references where FileManager.default.fileExists(atPath: reference.path) {
            do { try ScanResultStore.remove(reference) }
            catch { errors.append(error.localizedDescription) }
        }
        return errors
    }
    func home(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        for path in ["Downloads", "Documents", ".Trash", "unused-volumes", "Library/Application Support/AIYOUClean"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return url
    }
    func manager(_ home: URL) -> @Sendable () -> TrashManager {
        let history = home.appendingPathComponent("Library/Application Support/AIYOUClean/retention-history.sqlite3")
        let trash = home.appendingPathComponent(".Trash")
        return { TrashManager(storageURL: history, home: home, testTrash: trash) }
    }
    func inspector(_ home: URL) -> @Sendable () -> TrashInspector {
        { TrashInspector(home: home, volumesRoot: home.appendingPathComponent("unused-volumes")) }
    }
    func file(_ url: URL, scope: URL, index: Int = 0) throws -> ScanItem {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: UInt8(index % 200 + 20), count: index % 17 + 10)
        try data.write(to: url)
        return ScanItem(path: url.path, category: "generated retention fixture", bytes: Int64(data.count),
                        detail: "fixture-\(index)", canTrash: true, identity: FileSafety.identity(url), scopeRoot: scope.path)
    }
    func files(_ home: URL, count: Int, trash: Bool = false) throws -> [ScanItem] {
        let scope = home.appendingPathComponent(trash ? ".Trash" : "Downloads")
        return try (0..<count).map { try file(scope.appendingPathComponent(String(format: "entry-%04d.bin", $0)), scope: scope, index: $0) }
    }
    func change(_ item: ScanItem) throws { try Data(repeating: 42, count: 4099).write(to: URL(fileURLWithPath: item.path)) }
    func store(_ items: [ScanItem]) throws -> ScanResultReference {
        let store = try ScanResultStore.createTemporary(); try track(store.reference)
        for item in items { try store.append(item) }
        try store.flush(); return store.reference
    }
    func scanReport(_ items: [ScanItem], reference: ScanResultReference?) -> ScanReport {
        var report = ScanReport(kind: .downloads, items: reference == nil ? items : [])
        report.resultStore = reference; report.totalItemCount = items.count
        report.processableItemCount = items.filter(\.canTrash).count
        report.allItemsBytes = items.reduce(0) { $0 + $1.bytes }
        return report
    }
    func app(_ home: URL, items: [ScanItem], reference: ScanResultReference?) throws -> AppState {
        let state = AppState(taskCenter: DetectionTaskCenter(), trashManagerFactory: manager(home))
        state.destination = .scan(.downloads); state.largestFirst = false
        state.acceptReport(scanReport(items, reference: reference))
        try spin("standard initial page") { !state.pageLoading }
        try require(state.pageError == nil, "Standard initial page error: \(state.pageError ?? "")")
        return state
    }
    func wait(_ state: AppState) throws {
        try spin("standard cleanup acknowledgement") { !state.busy && !state.taskCenter.isBusy && !state.pageLoading }
        try require(state.pageError == nil, "Standard cleanup page error: \(state.pageError ?? "")")
    }
    func standard() throws {
        let home = try self.home("standard"), rows = try files(home, count: 402), reference = try store(rows)
        let state = try app(home, items: rows, reference: reference)
        state.query = "entry-"; try spin("standard search") { !state.pageLoading }
        state.nextPage(); try spin("standard page 1") { !state.pageLoading }
        state.nextPage(); try spin("standard page 2") { !state.pageLoading }
        try require(state.pageIndex == 2 && state.visibleItems.count == 2, "402-row standard tail page missing")
        let good = state.visibleItems[0], failed = state.visibleItems[1]
        try change(failed); state.toggle(good); state.toggle(failed); state.trashSelected(); try wait(state)
        let stats = try ScanResultStore(reference: reference).statistics()
        try require(state.latestReport?.resultStore == reference && state.reportItemCount == 401, "Standard partial success discarded/ref changed")
        try require(stats.totalCount == 401 && state.reportTotalBytes == rows.reduce(0, { $0 + $1.bytes }) - good.bytes, "Standard partial success statistics wrong")
        try require(state.query == "entry-" && !state.largestFirst && state.pageIndex == 2 && state.visibleItems.map(\.path) == [failed.path], "Standard query/sort/page or failed identity row was lost")
        try require(!FileManager.default.fileExists(atPath: good.path) && FileManager.default.fileExists(atPath: failed.path), "Standard mutation did not match real success/failure")
        try require(state.history.count == 1, "Standard factory did not record exactly one real move")
        state.toggle(state.visibleItems[0]); state.trashSelected(); try wait(state)
        try require(state.reportItemCount == 401 && state.latestReport?.resultStore == reference, "Standard zero-success failure reset report")
        state.previousPage(); try spin("standard return previous") { !state.pageLoading }
        let second = state.visibleItems[0]; state.toggle(second); state.trashSelected(); try wait(state)
        try require(state.reportItemCount == 400 && state.history.count == 2, "Standard remaining results cannot be selected and cleared again")
        evidence.append(["case": "standard-disk-partial", "initial": 402, "remaining": state.reportItemCount,
                         "queryPreserved": state.query == "entry-", "sameReference": state.latestReport?.resultStore == reference,
                         "realMoves": state.history.count, "failedIdentityRetained": true])

        let tailHome = try self.home("standard-tail"), tailRows = try files(tailHome, count: 201), tailRef = try store(tailRows)
        let tail = try app(tailHome, items: tailRows, reference: tailRef)
        tail.nextPage(); try spin("standard tail") { !tail.pageLoading }
        try require(tail.pageIndex == 1 && tail.visibleItems.count == 1, "Standard 201 tail missing")
        tail.toggle(tail.visibleItems[0]); tail.trashSelected(); try wait(tail)
        try require(tail.reportItemCount == 200 && tail.pageIndex == 0 && tail.visibleItems.count == 200 && tail.latestReport?.resultStore == tailRef, "Standard tail page did not clamp after cleanup")
        evidence.append(["case": "standard-tail-clamp", "remaining": tail.reportItemCount, "page": tail.pageIndex])

        let hiddenHome = try self.home("standard-hidden"), hiddenRows = try files(hiddenHome, count: 2), hiddenRef = try store(hiddenRows)
        let hidden = try app(hiddenHome, items: hiddenRows, reference: hiddenRef)
        hidden.toggle(hidden.visibleItems[0]); hidden.trashSelected()
        hidden.suspendPresentation(); hidden.destination = .dashboard
        try wait(hidden)
        try require(hidden.latestReport?.resultStore == hiddenRef && hidden.reportItemCount == 1, "Hidden standard completion lost report")
        hidden.destination = .scan(.downloads); hidden.resumePresentation()
        try spin("standard hidden return") { !hidden.pageLoading }
        try require(hidden.visibleItems.count == 1, "Standard hidden results not readable on return")
        evidence.append(["case": "standard-hidden-return", "remaining": hidden.reportItemCount])

        let fallbackHome = try self.home("standard-fallback"), fallbackRows = try files(fallbackHome, count: 3)
        let fallback = try app(fallbackHome, items: fallbackRows, reference: nil)
        let fallbackGood = fallback.visibleItems[0], fallbackFail = fallback.visibleItems[1]
        try change(fallbackFail); fallback.toggle(fallbackGood); fallback.toggle(fallbackFail); fallback.trashSelected(); try wait(fallback)
        try require(fallback.latestReport != nil && fallback.latestReport?.resultStore == nil && fallback.reportItemCount == 2 && fallback.visibleItems.count == 2, "Standard fallback partial cleanup lost report")
        try require(fallback.reportTotalBytes == fallbackRows.reduce(0, { $0 + $1.bytes }) - fallbackGood.bytes, "Fallback bytes not updated")
        fallback.toggle(fallback.visibleItems.first { $0.path == fallbackFail.path }!); fallback.trashSelected(); try wait(fallback)
        try require(fallback.reportItemCount == 2, "Fallback zero success reset report")
        evidence.append(["case": "standard-small-fallback", "remaining": fallback.reportItemCount])
    }

    func smartReport(home: URL, items: [ScanItem], reference: ScanResultReference?, readOnly: ScanResultReference? = nil, issues: ScanResultReference? = nil) -> SmartCareReport {
        // Public SmartCareReport's memberwise initializer is internal. The real
        // service rejects this explicit empty selected scope before any scan or
        // status command; its report is only a valid public value template.
        var report = SmartCareService().scan(options: SmartCareOptions(home: home, includeApplications: false, scanScope: .selectedFolders, roots: []))
        report.invalidated = false; report.incomplete = false; report.cancelled = false; report.warnings = []
        report.items = reference == nil ? items : []; report.resultStore = reference
        report.readOnlyStore = readOnly; report.readOnlyStoredCount = readOnly == nil ? 0 : 2
        report.diskCoverage = FullDiskCoverage(issueStore: issues, issueCount: issues == nil ? 0 : 2)
        report.totalItemCount = items.count; report.totalProcessableBytes = items.reduce(0) { $0 + $1.bytes }
        report.appliedIgnoreRules = []; return report
    }
    func smart(_ home: URL, report: SmartCareReport) throws -> SmartCareViewState {
        let state = SmartCareViewState(taskCenter: DetectionTaskCenter(), home: home, trashManagerFactory: manager(home))
        state.report = report; state.loadPage(0)
        try spin("smart initial page") { !state.pageLoading }
        try require(state.pageError == nil, "Smart initial page failed")
        return state
    }
    func wait(_ state: SmartCareViewState) throws {
        try spin("smart cleanup acknowledgement") { state.phase == nil && !state.taskCenter.isBusy && !state.pageLoading }
        try require(state.pageError == nil, "Smart cleanup page error")
    }
    func smartCare() throws {
        let home = try self.home("smart"), scope = home.appendingPathComponent("Documents")
        let parent = scope.appendingPathComponent("parent")
        let child = try file(parent.appendingPathComponent("child.bin"), scope: scope)
        let directory = ScanItem(path: parent.path, category: "fixture folder", bytes: child.bytes, canTrash: true,
                                 identity: FileSafety.identity(parent), scopeRoot: scope.path)
        let other = try file(scope.appendingPathComponent("other.bin"), scope: scope, index: 1)
        let failed = try file(scope.appendingPathComponent("failed.bin"), scope: scope, index: 2)
        let items = [directory, child, other, failed], reference = try store(items)
        let readOnly = try store([ScanItem(path: parent.appendingPathComponent("readonly.bin").path, category: "read-only"), ScanItem(path: scope.appendingPathComponent("readonly-other.bin").path, category: "read-only")])
        let issues = try store([ScanItem(path: parent.appendingPathComponent("issue.bin").path, category: "issue"), ScanItem(path: scope.appendingPathComponent("issue-other.bin").path, category: "issue")])
        let state = try smart(home, report: smartReport(home: home, items: items, reference: reference, readOnly: readOnly, issues: issues))
        try change(failed); state.selected = [directory.path, failed.path]; state.requestTrash()
        try require(state.confirmation != nil, "Smart confirmation absent")
        state.trash(state.confirmation!); state.stopOnDisappear(); try wait(state)
        try require(state.report != nil && state.report?.invalidated == false && state.report?.resultStore == reference, "Smart hidden completion invalidated/replaced report")
        state.resume(); try spin("smart hidden return") { !state.pageLoading }
        try require(state.pageItemCount == 2 && Set(state.pageItems.map(\.path)) == Set([other.path, failed.path]), "Smart parent success did not prune exactly parent and descendants")
        try require(state.report?.readOnlyStore == readOnly && state.report?.diskCoverage?.issueStore == issues, "Smart changed auxiliary references")
        try require(try ScanResultStore(reference: readOnly).statistics().totalCount == 1, "Smart readonly descendant retained or unrelated row lost")
        try require(try ScanResultStore(reference: issues).statistics().totalCount == 1, "Smart issue descendant retained or unrelated row lost")
        try require(state.report?.totalProcessableBytes == other.bytes + failed.bytes, "Smart remaining bytes wrong")
        state.selected = [failed.path]; state.requestTrash(); state.trash(state.confirmation!); try wait(state)
        try require(state.report?.totalItemCount == 2 && state.report?.invalidated == false, "Smart zero success reset report")
        state.selected = [other.path]; state.requestTrash(); state.trash(state.confirmation!); state.cancel()
        try require(state.taskCenter.isBusy, "Smart cancel released ticket before acknowledgement")
        try wait(state)
        try require(state.report?.totalItemCount == 2 && FileManager.default.fileExists(atPath: other.path), "Smart immediate cancellation reset report or moved unprocessed item")
        evidence.append(["case": "smart-three-stores-hidden", "remaining": state.report?.totalItemCount ?? -1,
                         "readOnly": state.report?.readOnlyStoredCount ?? -1, "issues": state.report?.diskCoverage?.issueCount ?? -1,
                         "invalidated": state.report?.invalidated ?? true, "cancelRetained": true])

        let tailHome = try self.home("smart-tail"), tailRows = try files(tailHome, count: 201), tailRef = try store(tailRows)
        let tail = try smart(tailHome, report: smartReport(home: tailHome, items: tailRows, reference: tailRef))
        tail.loadPage(1); try spin("smart tail page") { !tail.pageLoading }
        try require(tail.page == 1 && tail.pageItems.count == 1, "Smart tail page missing")
        tail.selected = [tail.pageItems[0].path]; tail.requestTrash(); tail.trash(tail.confirmation!); try wait(tail)
        try require(tail.report?.totalItemCount == 200 && tail.page == 0 && tail.pageItems.count == 200 && tail.report?.resultStore == tailRef, "Smart tail page did not clamp")
        evidence.append(["case": "smart-tail-clamp", "remaining": tail.report?.totalItemCount ?? -1, "page": tail.page])
    }

    func extendedReport(home: URL, items: [ScanItem], reference: ScanResultReference) throws -> ExtendedCleanupReport {
        // Safe public value template: the generated home has no developer-cache roots.
        var report = ExtendedCleanupScanner().scan(.developerCaches, options: ExtendedCleanupOptions(home: home))
        try track(report.resultStore)
        report.items = []; report.warnings = []; report.truncated = false; report.cancelled = false
        report.resultStore = reference; report.totalCount = items.count; report.processableCount = items.count
        report.totalBytes = items.reduce(0) { $0 + $1.bytes }; return report
    }
    func trashReport(home: URL) throws -> TrashInspectionReport {
        let report = inspector(home)().scan(options: ExtendedCleanupOptions(home: home))
        try track(report.resultStore)
        try require(!report.truncated && !report.cancelled, "Generated Trash inspection incomplete: \(report.warnings)")
        return report
    }
    func advanced(_ home: URL) -> AdvancedCleanupState {
        AdvancedCleanupState(taskCenter: DetectionTaskCenter(), trashManagerFactory: manager(home), trashInspectorFactory: inspector(home))
    }
    func wait(_ state: AdvancedCleanupState) throws {
        try spin("advanced cleanup acknowledgement") { !state.busy && !state.taskCenter.isBusy && !state.pageLoading }
        try require(state.pageError == nil && state.processingIndexError == nil, "Advanced result index failed")
    }
    func advancedCleanup() throws {
        let home = try self.home("advanced"), rows = try files(home, count: 3), reference = try store(rows)
        let otherTrashHome = try self.home("advanced-other-trash"); _ = try files(otherTrashHome, count: 1, trash: true)
        let untouchedTrash = try trashReport(home: otherTrashHome)
        let state = advanced(home); state.report = try extendedReport(home: home, items: rows, reference: reference)
        state.trashReport = untouchedTrash; state.loadPage(); try spin("advanced candidates") { !state.pageLoading }
        try change(rows[1]); state.selected = [rows[0].path, rows[1].path]; state.requestProcessing()
        try require(state.confirmation != nil, "Advanced move confirmation absent")
        state.perform(state.confirmation!); state.stopOnDisappear(); try wait(state)
        state.resumePresentation(); try spin("advanced hidden return") { !state.pageLoading }
        try require(state.report?.resultStore == reference && state.report?.totalCount == 2 && state.candidatePage.count == 2, "Advanced move partial success lost candidate report")
        try require(state.trashReport?.resultStore == untouchedTrash.resultStore && state.trashReport?.totalCount == 1, "Advanced move changed other-tab report")
        state.selected = [rows[1].path]; state.requestProcessing(); state.perform(state.confirmation!); try wait(state)
        try require(state.report?.totalCount == 2, "Advanced move zero success reset report")
        state.selected = [rows[2].path]; state.requestProcessing(); state.perform(state.confirmation!); state.cancel(); try wait(state)
        try require(state.report?.totalCount == 2 && FileManager.default.fileExists(atPath: rows[2].path), "Advanced cancelled move lost report or moved source")
        evidence.append(["case": "advanced-move-partial-hidden", "remaining": state.report?.totalCount ?? -1, "otherTabRetained": true])

        let tailHome = try self.home("advanced-tail"), tailRows = try files(tailHome, count: 201), tailRef = try store(tailRows)
        let tail = advanced(tailHome); tail.report = try extendedReport(home: tailHome, items: tailRows, reference: tailRef)
        tail.trashReport = untouchedTrash; tail.page = 1; tail.loadPage(); try spin("advanced move tail") { !tail.pageLoading }
        try require(tail.candidatePage.count == 1, "Advanced move tail missing")
        tail.selected = [tail.candidatePage[0].path]; tail.requestProcessing(); tail.perform(tail.confirmation!); try wait(tail)
        try require(tail.report?.totalCount == 200 && tail.page == 0 && tail.candidatePage.count == 200 && tail.report?.resultStore == tailRef, "Advanced move tail did not clamp")
        try require(tail.trashReport?.resultStore == untouchedTrash.resultStore, "Advanced tail move lost other tab")
        evidence.append(["case": "advanced-move-tail-clamp", "remaining": tail.report?.totalCount ?? -1, "page": tail.page])

        let permanentHome = try self.home("permanent"), permanentRows = try files(permanentHome, count: 3, trash: true)
        let permanentReport = try trashReport(home: permanentHome)
        let permanent = advanced(permanentHome); permanent.tab = .trash
        permanent.report = tail.report; permanent.trashReport = permanentReport; permanent.loadPage()
        try spin("permanent initial") { !permanent.pageLoading }
        let good = permanent.trashPage[0], failed = permanent.trashPage[1]
        try change(permanentRows.first { $0.path == failed.path }!)
        permanent.selected = [good.path, failed.path]; permanent.requestProcessing(); permanent.permanentPhrase = "永久删除"
        try require(permanent.confirmation != nil, "Permanent confirmation absent")
        permanent.perform(permanent.confirmation!); try wait(permanent)
        try require(permanent.trashReport?.resultStore == permanentReport.resultStore && permanent.trashReport?.totalCount == 2 && permanent.trashPage.count == 2, "Permanent partial success lost/pruned wrong trash report")
        try require(!FileManager.default.fileExists(atPath: good.path) && FileManager.default.fileExists(atPath: failed.path), "Permanent deletion did not match success/failure")
        try require(permanent.report?.resultStore == tailRef && permanent.report?.totalCount == 200, "Permanent deletion lost candidate tab")
        permanent.selected = [failed.path]; permanent.requestProcessing(); permanent.permanentPhrase = "永久删除"; permanent.perform(permanent.confirmation!); try wait(permanent)
        try require(permanent.trashReport?.totalCount == 2, "Permanent zero success reset report")
        evidence.append(["case": "advanced-permanent-partial", "remaining": permanent.trashReport?.totalCount ?? -1, "otherTabRetained": true])

        let permanentTailHome = try self.home("permanent-tail"); _ = try files(permanentTailHome, count: 201, trash: true)
        let permanentTailReport = try trashReport(home: permanentTailHome)
        let permanentTail = advanced(permanentTailHome); permanentTail.tab = .trash
        permanentTail.report = tail.report; permanentTail.trashReport = permanentTailReport; permanentTail.page = 1; permanentTail.loadPage()
        try spin("permanent tail") { !permanentTail.pageLoading }
        try require(permanentTail.trashPage.count == 1, "Permanent tail missing")
        permanentTail.selected = [permanentTail.trashPage[0].path]; permanentTail.requestProcessing(); permanentTail.permanentPhrase = "永久删除"
        permanentTail.perform(permanentTail.confirmation!); try wait(permanentTail)
        try require(permanentTail.trashReport?.totalCount == 200 && permanentTail.page == 0 && permanentTail.trashPage.count == 200 && permanentTail.trashReport?.resultStore == permanentTailReport.resultStore, "Permanent tail did not clamp")
        try require(permanentTail.report?.resultStore == tailRef, "Permanent tail lost candidate tab")
        evidence.append(["case": "advanced-permanent-tail-clamp", "remaining": permanentTail.trashReport?.totalCount ?? -1, "page": permanentTail.page])
    }
    func run() throws { try standard(); try smartCare(); try advancedCleanup() }
}

@main struct ResultRetentionMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "--cleanup-owned-refs" {
            do {
                let references = try JSONDecoder().decode([ScanResultReference].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
                for reference in references where FileManager.default.fileExists(atPath: reference.path) { try ScanResultStore.remove(reference) }
                print("PASS owned retention stores cleanup"); return
            } catch { fputs("FAIL cleanup: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        guard arguments.count == 5 else { fputs("Expected output.json fixture-root nonce registry.json\n", stderr); exit(2) }
        let output = URL(fileURLWithPath: arguments[1]), root = URL(fileURLWithPath: arguments[2])
        let registry = URL(fileURLWithPath: arguments[4])
        var result: [String: Any] = ["passed": false, "realCleanupCompletion": true, "realTrashManager": true, "realTrashInspector": true,
                                     "realHomeScanned": false, "userAppControlled": false]
        let harness = RetentionHarness(root: root, output: output, registry: registry)
        do {
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-owner.json"))) as? [String: String]
            guard root.deletingLastPathComponent().lastPathComponent == ".test-fixtures", marker?["nonce"] == arguments[3],
                  marker?["kind"] == "AIYOUClean.ResultRetentionFixture", !FileSafety.hasSymlinkComponent(root) else {
                throw RetentionFailure(text: "Fixture ownership/path validation failed")
            }
            _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
            try harness.run(); result["passed"] = true
        } catch { result["error"] = error.localizedDescription; fputs("FAIL \(error.localizedDescription)\n", stderr) }
        result["cases"] = harness.evidence; result["assertionCount"] = harness.assertions
        let cleanupErrors = harness.cleanup(); result["cleanupErrors"] = cleanupErrors
        if !cleanupErrors.isEmpty { result["passed"] = false }
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { fputs("FAIL writing evidence: \(error)\n", stderr); exit(1) }
        print("Retention assertions: \(harness.assertions); cases: \(harness.evidence.count); passed: \(result["passed"] ?? false)")
        exit(result["passed"] as? Bool == true ? 0 : 1)
    }
}
