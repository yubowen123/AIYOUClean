#!/usr/bin/env python3
"""Render production SmartCareView with generated whole-disk coverage/results.

After the main build finishes:
  python3 scripts/smart-care-layout-check.py --binary-dir .build/arm64-apple-macosx/release

Outputs analysis/ui-v050: eight mode/scope screenshots, OCR, geometry and state
checks. v040 evidence is never overwritten. No SwiftPM invocation, real scanning,
desktop screenshots, permission changes or cleanup of user files is performed.
--parse-only checks generated fixture syntax. --mock-store substitutes bounded
in-memory fixture pages; default mode uses three owned temporary SQLite stores.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
import tempfile

PROJECT = pathlib.Path(__file__).resolve().parent.parent


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f'Production source anchor changed: {before[:100]}')
    return source.replace(before, after, 1)


def replace_method(source, start, end, replacement):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f'Production method boundaries changed: {start}')
    prefix, remainder = source.split(start, 1)
    _, suffix = remainder.split(end, 1)
    return prefix + replacement + end + suffix


def store_binding(mock_store):
    if mock_store:
        return '''import Foundation
struct LayoutFixtureStoreReference: Sendable { let path: String; let sessionID: String }
func makeLayoutFixtureStores(items: [ScanItem], readOnly: [ScanItem], issues: [ScanItem]) throws -> (LayoutFixtureStoreReference?, LayoutFixtureStoreReference?, LayoutFixtureStoreReference?) { (nil, nil, nil) }
@MainActor func waitForLayoutFixtureRemoval(_ references: [LayoutFixtureStoreReference]) throws {}
'''.replace('import Foundation', 'import Foundation\nimport CleanRoomCore')
    return '''import Foundation
import CleanRoomCore
typealias LayoutFixtureStoreReference = ScanResultReference
func makeLayoutFixtureStores(items: [ScanItem], readOnly: [ScanItem], issues: [ScanItem]) throws -> (LayoutFixtureStoreReference?, LayoutFixtureStoreReference?, LayoutFixtureStoreReference?) {
    var references: [LayoutFixtureStoreReference] = []
    do {
        for rows in [items, readOnly, issues] {
            let store = try ScanResultStore.createTemporary()
            references.append(store.reference)
            for item in rows { try store.append(item) }
            try store.flush()
        }
        return (references[0], references[1], references[2])
    } catch {
        for reference in references { try? ScanResultStore.remove(reference) }
        throw error
    }
}
@MainActor func waitForLayoutFixtureRemoval(_ references: [LayoutFixtureStoreReference]) throws {
    let deadline = Date().addingTimeInterval(5)
    while references.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    let remaining = references.filter { FileManager.default.fileExists(atPath: $0.path) }
    if !remaining.isEmpty {
        for reference in remaining { try? ScanResultStore.remove(reference) }
        throw LayoutFailure.page("Three owned fixture stores were not released by UI state")
    }
}
'''


def prepare_source(scratch, mock_store):
    original = (PROJECT / 'Sources/CleanRoomMac/SmartCareView.swift').read_text()
    guide = (PROJECT / 'Sources/CleanRoomMac/PermissionGuideView.swift').read_text()
    source = original.replace('SmartCareReport', 'LayoutFixtureReport').replace('SmartCareModuleSummary', 'LayoutFixtureModuleSummary').replace('FullDiskCoverage', 'LayoutFixtureDiskCoverage').replace('SmartCareScanScope', 'LayoutFixtureScanScope').replace('ScanResultReference', 'LayoutFixtureStoreReference')
    source = replace_once(source, 'private final class SmartCareViewState:', 'final class SmartCareViewState:')
    source = replace_once(source, 'private struct SmartCareConfirmation:', 'struct SmartCareConfirmation:')
    source = replace_once(source, 'private enum SmartCareResultMode:', 'enum SmartCareResultMode:')
    source = replace_once(source, '    @StateObject private var state = SmartCareViewState()', '''    @StateObject private var state: SmartCareViewState
    init(layoutState: SmartCareViewState, expandCoverage: Bool) {
        _state = StateObject(wrappedValue: layoutState)
        _coverageExpanded = State(initialValue: expandCoverage)
    }''')
    source = replace_once(source, '    func resume() { presentationActive = true }', '''    func resume() { presentationActive = true }
    func seedLayoutFixture(_ fixture: LayoutFixtureReport, mode: SmartCareResultMode, scope: LayoutFixtureScanScope) {
        precondition(report == nil)
        cancelPage(); report = fixture; resultMode = mode; scanScope = scope
        roots = scope == .selectedFolders ? [URL(fileURLWithPath: "/generated-selected-folders/Work"), URL(fileURLWithPath: "/generated-selected-folders/Media")] : []
        pageItems = fixture.rows(for: mode); pageItemCount = pageItems.count; page = 0
        phase = nil; pageLoading = false; selected = []; confirmation = nil
    }''')
    source = replace_method(source, '    func scan() {', '\n    func cancel()', '    func scan() { message = "布局夹具已禁用真实扫描。" }\n')
    source = replace_method(source, '    func chooseRoots() {', '\n    func modeCount(', '    func chooseRoots() { message = "布局夹具不打开文件对话框。" }\n')
    source = replace_method(source, '    func trash(_ pending: SmartCareConfirmation) {', '\n    private func finish(', '    func trash(_ pending: SmartCareConfirmation) { message = "布局夹具已禁用真实清理。" }\n')
    if mock_store:
        source = replace_method(source, '    private nonisolated static func dispose(', '\n    func invalidateForOptions()', '    private nonisolated static func dispose(_ references: [LayoutFixtureStoreReference]) {}\n')
        source = replace_method(source, '    private func loadPage(_ index: Int) {', '\n    func requestTrash()', '''    private func loadPage(_ index: Int) {
        guard let report, !report.invalidated else { return }
        selected = []; confirmation = nil; pageError = nil; pageLoading = false
        let rows = report.rows(for: resultMode)
        pageItems = Array(rows.dropFirst(index * pageSize).prefix(pageSize)); pageItemCount = rows.count
        resolvedCounts[resultMode] = rows.count; page = index
    }
''')
        assert 'ScanResultStore' not in source
    (scratch / 'StoreFixtureBinding.swift').write_text(store_binding(mock_store))
    for before, after in [
        ('                controls\n', '                controls.background(SmartCareLayoutProbe(name: "scope"))\n'),
        ('                    candidateSummary(report)', '                    candidateSummary(report).background(SmartCareLayoutProbe(name: "summary"))'),
        ('if let coverage = report.diskCoverage { coveragePanel(coverage) }', 'if let coverage = report.diskCoverage { coveragePanel(coverage).background(SmartCareLayoutProbe(name: "coverage")) }'),
        ('if needsAccessHelp(report) { permissionNotice }', 'if needsAccessHelp(report) { permissionNotice.background(SmartCareLayoutProbe(name: "permissionNotice")) }'),
        ('                    resultModePicker\n', '                    resultModePicker.background(SmartCareLayoutProbe(name: "modes"))\n'),
        ('                    candidateList(report)', '                    candidateList(report).background(SmartCareLayoutProbe(name: "candidates"))'),
        ('if let report = state.report { actionBar(report) }', 'if let report = state.report { actionBar(report).background(SmartCareLayoutProbe(name: "footer")) }'),
        ('Button("访问权限引导…") { showingAccessGuide = true }.font(.caption)', 'Button("访问权限引导…") { showingAccessGuide = true }.font(.caption).background(SmartCareLayoutProbe(name: "permissionEntry"))'),
    ]:
        source = replace_once(source, before, after)
    cleanup = 'Button("清理所选…") { state.requestTrash() }.buttonStyle(.borderedProminent).tint(smartAccent).disabled(state.busy || state.selected.isEmpty || report.invalidated)'
    source = replace_once(source, cleanup, cleanup + '.background(SmartCareLayoutProbe(name: "cleanup"))')
    assert 'SmartCareService().scan(' not in source and 'TrashManager().trash(' not in source
    checks = {
        'fdaRequiresManualCurrentVersion': '需在系统设置中手动添加并启用当前运行版本' in guide,
        'fdaNotInferredFromError': '不能仅凭一次失败断定缺少完整磁盘访问' in guide,
        'otherAccessControlsExplained': 'ACL' in guide and '系统保护' in guide,
        'guideCanLocateCurrentBundle': 'activateFileViewerSelecting([Bundle.main.bundleURL])' in guide,
        'guideCanCopyVersionAndPath': '复制版本与应用路径' in guide and 'NSPasteboard.general.setString' in guide,
        'guideHasSettingsAndRecheck': 'Privacy_AllFiles' in guide and 'onRescan()' in guide,
        'defaultsToAllLocalDisks': 'var scanScope: SmartCareScanScope = .allLocalDisks' in original,
        'localMaintenanceNotInPicker': 'tag(SmartCareScanScope.localMaintenance)' not in original,
    }
    if not all(checks.values()): raise RuntimeError(f'Permission/scope policy regression: {checks}')
    (scratch / 'SmartCareView.swift').write_text(source)
    main = (PROJECT / 'Sources/CleanRoomMac/MainView.swift').read_text()
    heading = main[main.index('struct PageHeading: View {'):main.index('struct DashboardView: View {')]
    palette = '\n'.join(line for line in main.splitlines() if line.startswith('private let accent =') or line.startswith('private let secondaryText ='))
    (scratch / 'PageHeading.swift').write_text('import SwiftUI\n' + palette + '\n' + heading)
    return checks, {'SmartCareView.swift': hashlib.sha256(original.encode()).hexdigest(), 'MainView.swift': hashlib.sha256(main.encode()).hexdigest(), 'PermissionGuideView.swift': hashlib.sha256(guide.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary-dir', type=pathlib.Path)
    parser.add_argument('--output-dir', type=pathlib.Path, default=PROJECT / 'analysis/ui-v050')
    parser.add_argument('--parse-only', action='store_true')
    parser.add_argument('--mock-store', action='store_true')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output == (PROJECT / 'analysis/ui-v040').resolve(): raise RuntimeError('v040 evidence is preserved; use analysis/ui-v050 or a new output directory')
    output.mkdir(parents=True, exist_ok=True)
    binary_dir = (args.binary_dir or PROJECT / f'.build/{platform.machine()}-apple-macosx/release').resolve()
    with tempfile.TemporaryDirectory(prefix='aiyouclean-smart-layout-') as temporary:
        scratch = pathlib.Path(temporary)
        checks, hashes = prepare_source(scratch, args.mock_store)
        sources = [scratch / 'SmartCareView.swift', scratch / 'PageHeading.swift', scratch / 'StoreFixtureBinding.swift', PROJECT / 'Sources/CleanRoomMac/PermissionGuideView.swift', PROJECT / 'Tests/SmartCareUILayoutChecks/main.swift']
        manifest = {
            'kind': 'isolated-whole-disk-ui-layout-fixture', 'sizes': [[1080, 730], [1220, 820]],
            'scenarios': ['processable-1080x730', 'processable-1220x820', 'readonly-1080x730', 'readonly-1220x820', 'issues-1080x730', 'issues-1220x820', 'coverage-expanded-1220x820', 'selected-folders-1220x820'],
            'sidebarWidthPoints': 235, 'processableCandidates': 31, 'readOnlyItems': 11, 'inaccessibleEntries': 3, 'issueCount': 6,
            'sourceSHA256': hashes, 'permissionPolicyChecks': checks,
            'transforms': ['test-only constructible scope/report/coverage models', 'seeded generated results', 'scan/trash/dialog actions disabled', 'background geometry probes', 'real production PageHeading'],
            'doesNotVerify': ['actual full-disk scan coverage', 'actual macOS permission grants', 'real cleanup', 'production app bundle'],
            'dataOrigin': 'generated fixtures only; no user disk content is read',
            'swiftPMInvoked': False, 'binaryDirectory': str(binary_dir), 'rendered': False, 'resultStoreStubbed': args.mock_store,
        }
        manifest_path = output / 'manifest.json'
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        if args.parse_only:
            subprocess.run(['swiftc', '-frontend', '-parse', *map(str, sources)], cwd=PROJECT, check=True, timeout=60)
            print(f'PASS v050 fixture syntax and permission/scope policy checks; rendering not run: {output}')
            return
        objects = sorted((binary_dir / 'CleanRoomCore.build').glob('*.o'))
        if not objects or not (binary_dir / 'Modules/CleanRoomCore.swiftmodule').exists(): raise RuntimeError('Finish the main Core build first; this script does not invoke SwiftPM')
        executable = scratch / 'SmartCareLayoutChecks'
        command = ['swiftc', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3', *map(str, sources), *map(str, objects), '-o', str(executable)]
        subprocess.run(command, cwd=PROJECT, check=True, timeout=180)
        manifest['renderAttempted'] = True; manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        result = subprocess.run([str(executable), str(output)], cwd=PROJECT, check=False, timeout=180)
        manifest['rendered'] = all((output / f'smart-care-{name}.png').exists() for name in manifest['scenarios'])
        manifest['passed'] = result.returncode == 0
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        result.check_returncode()
        print(f'PASS v050 SmartCare layout/state/owned-store release: {output / "layout-results.json"}')


if __name__ == '__main__':
    try: main()
    except subprocess.CalledProcessError as error:
        print(f'FAIL isolated validation command (exit {error.returncode}); see diagnostics above.', file=sys.stderr)
        raise SystemExit(error.returncode)
