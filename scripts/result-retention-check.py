#!/usr/bin/env python3
"""Isolated real-controller cleanup-retention regression; never runs SwiftPM.

Only generated project fixtures are moved/deleted. UI source copies expose
private access; AppState read-only machine telemetry uses a fixture snapshot.
Cleanup/completion, pruning, TrashManager and TrashInspector are unchanged.
Unrendered destination View stubs are compile dependencies only, not evidence.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import time
import uuid

PROJECT = pathlib.Path(__file__).resolve().parent.parent
GUI = PROJECT / 'Sources/CleanRoomMac'
UI_SOURCES = ['AppState', 'SmartCareView', 'AdvancedCleanupView',
              'DetectionTaskCenter', 'MainView', 'SupportingViews', 'PermissionGuideView']


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def prepare_sources(directory):
    directory.mkdir()
    manifest = {}
    for name in UI_SOURCES:
        original = (GUI / (name + '.swift')).read_text()
        source = original
        transforms = []
        if name in ['AppState', 'SmartCareView', 'AdvancedCleanupView']:
            if 'trashManagerFactory:' not in source:
                raise RuntimeError(f'{name}: missing injected real TrashManager factory')
            source = source.replace('private(set) ', '').replace('private ', '')
            transforms.append('access-control-only')
        if name == 'AppState':
            if original.count('SystemInfo.snapshot()') != 2:
                raise RuntimeError('AppState telemetry source anchor changed')
            source = source.replace('SystemInfo.snapshot()', 'RetentionFixture.snapshot()')
            transforms.append('read-only-system-telemetry-fixture')
            # Default factories are intentionally preserved and always injected
            # by Native tests. Actual history access must use that factory.
            for method in ['func reloadHistory()', 'func olderHistory()']:
                body = original.split(method, 1)[1].split('\n    }', 1)[0]
                if 'trashManagerFactory()' not in body or 'TrashManager()' in body:
                    raise RuntimeError('History access bypasses injected factory')
            if 'removeProcessedPaths(paths)' not in original:
                raise RuntimeError('AppState lacks retention/prune implementation')
        if name == 'AdvancedCleanupView' and 'trashInspectorFactory:' not in original:
            raise RuntimeError('Missing injected real TrashInspector factory')
        copied = directory / (name + '.swift')
        copied.write_text(source)
        manifest[name + '.swift'] = {
            'productionSHA256': hashlib.sha256(original.encode()).hexdigest(),
            'testCopySHA256': hashlib.sha256(source.encode()).hexdigest(),
            'transforms': transforms,
        }
    dependencies = ['SpaceLensView', 'OperationsView', 'MalwareView', 'MonitorView',
                    'BrowserPrivacyView', 'PreferencesView']
    stub_source = 'import SwiftUI\n'
    for name in dependencies:
        stub_source += (f'struct {name}: View {{\n'
                        '    init(registry: FeatureStateRegistry? = nil) {}\n'
                        '    var body: some View { EmptyView() }\n}\n')
    (directory / 'UnrenderedDestinations.swift').write_text(stub_source)
    (directory / 'ResultRetentionMain.swift').write_text((PROJECT / 'Tests/ResultRetentionChecks/main.swift').read_text())
    return manifest


def release_objects(binary_dir):
    objects = sorted((binary_dir / 'CleanRoomCore.build').glob('*.o'))
    if not objects or not (binary_dir / 'Modules/CleanRoomCore.swiftmodule').exists():
        raise RuntimeError('Complete release Core first; this script never invokes SwiftPM')
    for source in (PROJECT / 'Sources/CleanRoomCore').glob('*.swift'):
        built = binary_dir / 'CleanRoomCore.build' / (source.name + '.o')
        if not built.exists() or source.stat().st_mtime > built.stat().st_mtime + 1:
            raise RuntimeError(f'Release Core missing/stale: {source.name}')
    return objects


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=pathlib.Path,
                        default=PROJECT / '.build' / (platform.machine() + '-apple-macosx') / 'release')
    parser.add_argument('--output-dir', '--output', dest='output', type=pathlib.Path,
                        default=PROJECT / 'analysis/retention-v062/ui')
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    base = PROJECT / '.test-fixtures'; base.mkdir(exist_ok=True)
    root = base / ('result-retention-' + str(uuid.uuid4())); root.mkdir(mode=0o700)
    nonce = str(uuid.uuid4())
    write_json(root / 'fixture-owner.json', {'kind': 'AIYOUClean.ResultRetentionFixture', 'nonce': nonce})
    registry = output / 'owned-stores.json'
    write_json(registry, [])
    executable = root / 'ResultRetentionChecks'
    manifest = {'passed': False, 'parseOnly': args.parse_only, 'executed': False,
                'swiftPMInvoked': False, 'userAppControlled': False,
                'cleanupCompletionReplaced': False, 'trashManagerStubbed': False,
                'trashInspectorStubbed': False,
                'boundaries': ['nonce-owned generated fake homes, history and Trash only',
                               'actual production controller cleanup and completion bodies',
                               'public empty-scope SmartCare value template; no real scan',
                               'Extended developer-cache template scans generated empty home only',
                               'real TrashInspector scans generated .Trash only',
                               'unrendered destinations are compile-only View stubs',
                               'AppState machine telemetry replaced with fixture snapshot']}
    cleanup_safe = True
    try:
        sources = root / 'sources'; manifest['sources'] = prepare_sources(sources)
        paths = sorted(sources.glob('*.swift'))
        with (output / 'parse.log').open('w') as log:
            subprocess.run(['swiftc', '-frontend', '-parse', *map(str, paths)], cwd=PROJECT,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        manifest['parsePassed'] = True
        if not args.parse_only:
            objects = release_objects(args.binary_dir.resolve())
            manifest['coreObjectsSHA256'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in objects}
            command = ['swiftc', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0',
                       '-parse-as-library', '-I', str(args.binary_dir.resolve() / 'Modules'),
                       '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3',
                       *map(str, paths), *map(str, objects), '-o', str(executable)]
            with (output / 'compile.log').open('w') as log:
                subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            manifest['executed'] = True; started = time.monotonic()
            with (output / 'native.log').open('w') as log:
                child = subprocess.Popen([str(executable), str(output / 'retention-results.json'), str(root), nonce, str(registry)],
                                         cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT)
                try:
                    code = child.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
                    raise RuntimeError('Isolated retention worker exceeded 180s watchdog')
            manifest['exitCode'] = code; manifest['wallSeconds'] = time.monotonic() - started
            result_path = output / 'retention-results.json'
            result = json.loads(result_path.read_text()) if result_path.exists() else {}
            manifest['passed'] = code == 0 and result.get('passed') is True
            if not manifest['passed']:
                raise RuntimeError(f'Native retention regression failed: {result.get("error", "see native.log")}')
        else:
            manifest['passed'] = True  # Syntax only, explicitly not runtime evidence.
    except Exception as error:
        manifest['error'] = str(error)
    finally:
        if executable.exists():
            try:
                cleanup = subprocess.run([str(executable), '--cleanup-owned-refs', str(registry)],
                                         cwd=PROJECT, capture_output=True, text=True, timeout=30)
                manifest['cleanup'] = {'exitCode': cleanup.returncode, 'stdout': cleanup.stdout, 'stderr': cleanup.stderr}
                cleanup_safe = cleanup.returncode == 0
            except Exception as error:
                cleanup_safe = False; manifest['cleanupError'] = str(error)
        marker = root / 'fixture-owner.json'
        valid_marker = not root.is_symlink() and root.parent.resolve() == base.resolve() and json.loads(marker.read_text()).get('nonce') == nonce
        if cleanup_safe and valid_marker:
            shutil.rmtree(root); manifest['fixtureRemoved'] = True
        else:
            manifest['fixtureRemoved'] = False; manifest['retainedFixture'] = str(root)
            manifest['passed'] = False
        write_json(output / 'manifest.json', manifest)
    if not manifest['passed']:
        raise RuntimeError(manifest.get('error', 'Fixture cleanup failed'))
    print(('PASS syntax/source anchors only; native not executed: ' if args.parse_only else 'PASS real cleanup retention: ') + str(output))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('FAIL ' + str(error), file=sys.stderr)
        raise SystemExit(1)
