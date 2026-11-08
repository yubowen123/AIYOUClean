#!/usr/bin/env python3
"""Render the real ScanView footer with generated reports; never invokes SwiftPM.

Other destinations are stubs only for this single-page geometry check. Real
multi-controller lifecycle behavior is covered by task-lifecycle-check.py.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import tempfile
import uuid

PROJECT = pathlib.Path(__file__).resolve().parent.parent


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError('Production source anchor changed: ' + before[:120])
    return source.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('legacy_output', nargs='?', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--binary-dir', type=pathlib.Path, default=PROJECT / '.build' / (platform.machine() + '-apple-macosx') / 'release')
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    output = (args.output or args.legacy_output or PROJECT / 'analysis/layout-v060.json').resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    metadata = output.with_name(output.stem + '-manifest.json')
    manifest = {'passed': False, 'executed': False, 'swiftPMInvoked': False,
                'realScanView': True, 'otherDestinationsStubbed': True,
                'userAppControlled': False, 'realFilesScannedOrCleaned': False,
                'bitmapLimitation': 'Native sidebar/taskbar drawing can be blank in offscreen NSHostingView capture; ScanView/footer/cleanup controls are rendered and geometrically checked.',
                'sizesPoints': [[1080, 730], [1220, 820]], 'states': ['idle', 'other-task-running']}
    base = PROJECT / '.test-fixtures'; base.mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='layout-v060-' + str(uuid.uuid4()) + '-', dir=base) as temporary:
            scratch = pathlib.Path(temporary)
            originals = {name: (PROJECT / 'Sources/CleanRoomMac' / name).read_text() for name in ['AppState.swift', 'MainView.swift', 'DetectionTaskCenter.swift', 'SupportingViews.swift', 'PermissionGuideView.swift']}
            manifest['sourceSHA256'] = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in originals.items()}
            state = replace_once(originals['AppState.swift'], 'private func acceptReport(', 'func acceptReport(')
            state = replace_once(state, '        reloadHistory()\n', '        // Generated layout data: skip real cleanup history.\n')
            (scratch / 'AppState.swift').write_text(state)
            view = originals['MainView.swift']
            anchor = '.onDisappear { state.clearSelection(); state.showTrashConfirmation = false }'
            view = replace_once(view, anchor, '.background(LayoutProbe(name: "scan"))\n            ' + anchor)
            for anchor, name in [('.overlay(alignment: .top) { Divider() }', 'footer'),
                                 ('.overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05)))', 'list'),
                                 ('.accessibilityIdentifier("scan.cleanup")', 'cleanup'),
                                 ('.accessibilityIdentifier("navigation.sidebar")', 'sidebar')]:
                view = replace_once(view, anchor, anchor + f'.background(LayoutProbe(name: "{name}"))')
            anchor = 'Label("清理所选…", systemImage: "trash")'
            view = replace_once(view, anchor, anchor + '.background(LayoutEnabledProbe(name: "cleanup"))')
            (scratch / 'MainView.swift').write_text(view)
            center = originals['DetectionTaskCenter.swift']
            anchor = '.accessibilityIdentifier("task.banner")'
            center = replace_once(center, anchor, anchor + '.background(LayoutProbe(name: "taskBanner"))')
            (scratch / 'DetectionTaskCenter.swift').write_text(center)
            names = ['SmartCareView', 'SpaceLensView', 'OperationsView', 'MalwareView', 'MonitorView', 'AdvancedCleanupView', 'BrowserPrivacyView', 'PreferencesView']
            stubs = 'import SwiftUI\n' + '\n'.join(f'@MainActor struct {name}: View {{ init(registry: FeatureStateRegistry? = nil) {{}}; var body: some View {{ EmptyView() }} }}' for name in names)
            (scratch / 'OtherDestinations.swift').write_text(stubs + '\n')
            for name in ['SupportingViews.swift', 'PermissionGuideView.swift']:
                (scratch / name).write_text(originals[name])
            (scratch / 'LayoutMain.swift').write_text((PROJECT / 'Tests/UILayoutChecks/main.swift').read_text())
            sources = sorted(scratch.glob('*.swift'))
            subprocess.run(['swiftc', '-frontend', '-parse', *map(str, sources)], cwd=PROJECT, check=True, timeout=60)
            manifest['sourceAnchorsValidated'] = True; manifest['parsePassed'] = True
            if args.parse_only:
                metadata.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
                print('PASS source anchors/syntax only; layout not executed: ' + str(metadata))
                return
            binary = args.binary_dir.resolve()
            objects = sorted((binary / 'CleanRoomCore.build').glob('*.o'))
            if not objects or not (binary / 'Modules/CleanRoomCore.swiftmodule').exists():
                raise RuntimeError('Root must finish the release Core build; this script never invokes SwiftPM')
            executable = scratch / 'LayoutChecks'
            command = ['swiftc', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0', '-parse-as-library',
                       '-I', str(binary / 'Modules'), '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3',
                       *map(str, sources), *map(str, objects), '-o', str(executable)]
            with output.with_name(output.stem + '-compile.log').open('w') as log:
                subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            manifest['executed'] = True
            with output.with_name(output.stem + '-native.log').open('w') as log:
                result = subprocess.run([str(executable), str(output)], cwd=PROJECT, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=90, check=False)
            manifest['exitCode'] = result.returncode
            manifest['passed'] = result.returncode == 0 and output.exists() and json.loads(output.read_text()).get('passed') is True
            if not manifest['passed']:
                raise RuntimeError('Layout regression failed; inspect ' + str(output))
            metadata.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
            print('PASS real ScanView footer/cleanup visibility in four scenarios: ' + str(output))
    except Exception as error:
        manifest['error'] = str(error)
        metadata.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        raise


if __name__ == '__main__':
    main()
