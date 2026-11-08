#!/usr/bin/env python3
"""Render current production SwiftUI content views with generated documentation data.

Run bash scripts/build.sh first. No SwiftPM invocation, real scan, cleanup,
user screenshot, permissions request, or real home access occurs here.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import tempfile

PROJECT = pathlib.Path(__file__).resolve().parent.parent
GUI = PROJECT / 'Sources/CleanRoomMac'


def method(source, start, end, replacement):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError('Production source anchors changed: ' + start)
    prefix, body = source.split(start, 1)
    _, suffix = body.split(end, 1)
    return prefix + replacement + end + suffix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=pathlib.Path, default=PROJECT / '.build' / (platform.machine() + '-apple-macosx/release'))
    parser.add_argument('--output-dir', type=pathlib.Path, default=PROJECT / 'docs/images/screenshots')
    args = parser.parse_args()
    output = args.output_dir.resolve(); output.mkdir(parents=True, exist_ok=True)
    binary = args.binary_dir.resolve()
    names = ['SmartCareView', 'AppState', 'MainView', 'SupportingViews', 'PermissionGuideView', 'DetectionTaskCenter']
    receipt = {'kind': 'production-swiftui-content-documentation-screenshots', 'version': '0.6.2',
               'data': 'generated /Users/demo paths and sizes; no user content',
               'userAppControlled': False, 'realHomeAccessed': False, 'realFilesScannedOrCleaned': False,
               'viewScope': 'production content views, no sidebar; outer documentation label added', 'sourceSHA256': {}}
    with tempfile.TemporaryDirectory(prefix='aiyouclean-docs-') as temporary:
        scratch = pathlib.Path(temporary)
        for name in names:
            original = (GUI / (name + '.swift')).read_text()
            receipt['sourceSHA256'][name + '.swift'] = hashlib.sha256(original.encode()).hexdigest()
            source = original
            if name in ['SmartCareView', 'AppState']:
                source = source.replace('private(set) ', '').replace('private ', '')
            if name == 'SmartCareView':
                source = source.replace('SmartCareReport', 'DocsSmartReport').replace('SmartCareModuleSummary', 'DocsModuleSummary')
                source = method(source, '    func scan() {', '\n    func cancel()', '    func scan() { message = "演示数据：不执行扫描。" }\n')
                source = method(source, '    func trash(_ pending: SmartCareConfirmation) {', '\n    func acceptsCleanup', '    func trash(_ pending: SmartCareConfirmation) { message = "演示数据：不执行清理。" }\n')
                source = method(source, '    func chooseRoots() {', '\n    func modeCount', '    func chooseRoots() { message = "演示数据：不打开文件夹。" }\n')
            if name == 'AppState':
                assert source.count('SystemInfo.snapshot()') == 2
                source = source.replace('SystemInfo.snapshot()', 'DocsFixture.snapshot()')
                source = method(source, '    func chooseRoots() {', '\n    func resetRoots()', '    func chooseRoots() { message = "演示数据：不打开文件夹。" }\n')
                source = method(source, '    func scan() {', '\n    func cancelScan()', '    func scan() { message = "演示数据：不执行扫描。" }\n')
                source = method(source, '    func trashSelected() {', '\n    func completeTrash', '    func trashSelected() { message = "演示数据：不执行清理。" }\n')
            (scratch / (name + '.swift')).write_text(source)
        stubs = 'import SwiftUI\n' + '\n'.join('struct '+n+': View { init(registry: FeatureStateRegistry? = nil) {} ; var body: some View { EmptyView() } }' for n in ['SpaceLensView', 'OperationsView', 'MalwareView', 'MonitorView', 'AdvancedCleanupView', 'BrowserPrivacyView', 'PreferencesView'])
        (scratch / 'UnrenderedDestinations.swift').write_text(stubs)
        (scratch / 'DocsMain.swift').write_text((PROJECT / 'Tests/DocsScreenshots/main.swift').read_text())
        objects = sorted((binary / 'CleanRoomCore.build').glob('*.o'))
        if not objects or not (binary / 'Modules/CleanRoomCore.swiftmodule').exists():
            raise RuntimeError('Build Core release first; this script never invokes SwiftPM.')
        sources = sorted(scratch.glob('*.swift'))
        executable = scratch / 'DocsScreenshots'
        command = ['swiftc', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0', '-parse-as-library', '-I', str(binary / 'Modules'), '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3', *map(str, sources), *map(str, objects), '-o', str(executable)]
        with (output / 'compile.log').open('w') as log:
            result = subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if result.returncode:
            raise RuntimeError('Compilation failed; see ' + str(output / 'compile.log'))
        result = subprocess.run([str(executable), str(output)], cwd=PROJECT, timeout=90, check=False, capture_output=True, text=True)
        (output / 'render.log').write_text(result.stdout + result.stderr)
        receipt['passed'] = result.returncode == 0
        receipt['transforms'] = ['expose state access only in temporary copies', 'SmartCareReport/ModuleSummary constructible documentation equivalents', 'scan/cleanup/file dialogs disabled in temporary copy', 'AppState telemetry fixture and generated-home history factory', 'other unused destinations are compile-only EmptyView stubs']
        (output / 'render-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        result.check_returncode()
        checks_path = output / 'screenshots-check.json'
        checks = json.loads(checks_path.read_text())
        for row in checks['screenshots']:
            row['sha256'] = hashlib.sha256((output / row['image']).read_bytes()).hexdigest()
        checks_path.write_text(json.dumps(checks, ensure_ascii=False, indent=2) + '\n')
        for name in ['compile.log', 'render.log']:
            path = output / name
            if path.exists() and path.stat().st_size == 0:
                path.unlink()
        print('PASS documentation screenshots: ' + str(output))

if __name__ == '__main__':
    main()
