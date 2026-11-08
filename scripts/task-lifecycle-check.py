#!/usr/bin/env python3
"""Isolated production-UI lifecycle regression; never invokes SwiftPM.

Uses existing release Core objects and temporary copies of actual UI sources.
The copies expose private test state, inject an owned fake home, and gate real
progress callbacks to make navigation/cancellation timing deterministic. No
Scanner/SmartCareService execution path or returned result is replaced.
"""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import platform
import shutil
import signal
import subprocess
import sys
import time
import uuid

PROJECT = pathlib.Path(__file__).resolve().parent.parent
GUI = PROJECT / 'Sources/CleanRoomMac'
UI_SOURCES = ['AppState', 'MainView', 'DetectionTaskCenter', 'SupportingViews',
              'PermissionGuideView', 'SmartCareView', 'SpaceLensView',
              'AdvancedCleanupView', 'MalwareView', 'BrowserPrivacyView',
              'OperationsView', 'PreferencesView', 'MonitorView']
DUPLICATES = 2602
LARGE_BYTES = 100_000_123
RSS_LIMIT = 512 * 1024 * 1024


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f'Production source anchor changed: {before[:120]}')
    return source.replace(before, after, 1)


def open_private(source):
    # Visibility only; no method body or production control flow is replaced.
    return source.replace('private(set) ', '').replace('private ', '')


@contextlib.contextmanager
def owned_fixture():
    base = PROJECT / '.test-fixtures'
    base.mkdir(exist_ok=True)
    root = base / ('task-lifecycle-' + str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    nonce = str(uuid.uuid4())
    write_json(root / 'fixture-owner.json', {'kind': 'AIYOUClean.TaskLifecycleFixture',
                                           'nonce': nonce, 'duplicates': DUPLICATES,
                                           'largeBytes': LARGE_BYTES})
    try:
        yield root, nonce
    finally:
        # Delete only the nonce-marked fixture created by this process.
        marker = root / 'fixture-owner.json'
        if root.is_symlink() or root.parent.resolve() != base.resolve():
            raise RuntimeError('Fixture ownership/path changed; refusing cleanup')
        if json.loads(marker.read_text()).get('nonce') != nonce:
            raise RuntimeError('Fixture nonce changed; refusing cleanup')
        shutil.rmtree(root)


def prepare_sources(directory):
    directory.mkdir()
    originals = {name: (GUI / (name + '.swift')).read_text() for name in UI_SOURCES}
    for name, source in originals.items():
        if name == 'AppState':
            source = replace_once(source, '        reloadHistory()\n',
                                  '        // Owned fixture: do not read real cleanup history.\n')
            source = replace_once(source, 'private func setRoots(', 'func setRoots(')
            source = replace_once(source, 'let options = ScanOptions(roots:',
                                  'let options = ScanOptions(home: LifecycleFixture.home, roots:')
            source = replace_once(source, 'progress: { count, path in slot.publish(count, path) }',
                                  'progress: { count, path in slot.publish(count, path); LifecycleFixture.gate.wait() }')
        elif name == 'SmartCareView':
            source = replace_once(source, 'let options = SmartCareOptions(home: home, includeApplications:',
                                  'let options = SmartCareOptions(home: LifecycleFixture.home, includeApplications:')
            source = replace_once(source, 'progress: { slot.publish($0) }',
                                  'progress: { value in slot.publish(value); if value.visitedFiles > 0 && value.phase == nil { LifecycleFixture.gate.wait() } }')
            source = open_private(source)
        elif name == 'SpaceLensView':
            source = replace_once(source, 'progress:{count,path in box.offer(count,path)}',
                                  'progress:{count,path in box.offer(count,path); LifecycleFixture.gate.wait()}')
            source = open_private(source)
        elif name in ['AdvancedCleanupView', 'MalwareView', 'BrowserPrivacyView', 'OperationsView']:
            source = open_private(source)
        if name == 'DetectionTaskCenter':
            for identifier, marker in [('task.banner', 'banner'), ('task.return', 'return'),
                                       ('task.cancel', 'cancel'), ('task.result', 'result')]:
                anchor = f'.accessibilityIdentifier("{identifier}")'
                source = replace_once(source, anchor, anchor + f'.background(TaskLifecycleProbe(name: "{marker}"))')
        if name == 'MainView':
            anchor = '.accessibilityIdentifier("navigation.sidebar")'
            source = replace_once(source, anchor, anchor + '.background(TaskLifecycleProbe(name: "sidebar"))')
            sidebar = source.split('private var sidebar:', 1)[1].split('@ViewBuilder private func nav', 1)[0]
            if '.disabled(state.busy)' in sidebar or '.disabled(state.detectionUnavailable)' in sidebar:
                raise RuntimeError('Navigation remains disabled while a detection runs')
            for view in ['SmartCareView', 'SpaceLensView', 'OperationsView', 'MalwareView', 'AdvancedCleanupView', 'BrowserPrivacyView']:
                if f'{view}(registry: state.featureStates)' not in source:
                    raise RuntimeError(f'{view} does not use the AppState registry')
        (directory / (name + '.swift')).write_text(source)
    (directory / 'TaskLifecycleMain.swift').write_text((PROJECT / 'Tests/TaskLifecycleChecks/main.swift').read_text())
    return originals


def create_files(root):
    home = root / 'home'
    (root / 'runtime').mkdir(mode=0o700)
    for group in range(3):
        (home / 'Downloads' / f'group-{group}').mkdir(parents=True)
    payload = b'AIYOUClean owned lifecycle fixture content'.ljust(64, b'.')
    for index in range(DUPLICATES):
        (home / 'Downloads' / f'group-{index % 3}' / f'copy-{index:05}.bin').write_bytes(payload)
    with (home / 'Downloads' / 'unique-large.bin').open('wb') as handle:
        handle.truncate(LARGE_BYTES)  # Unique size: metadata only, no duplicate hash.
    return home


def release_objects(binary_dir):
    objects = sorted((binary_dir / 'CleanRoomCore.build').glob('*.o'))
    if not objects or not (binary_dir / 'Modules/CleanRoomCore.swiftmodule').exists():
        raise RuntimeError('Root must complete the release Core build first; this script never invokes SwiftPM')
    for source in (PROJECT / 'Sources/CleanRoomCore').glob('*.swift'):
        built = binary_dir / 'CleanRoomCore.build' / (source.name + '.o')
        if not built.exists() or source.stat().st_mtime > built.stat().st_mtime + 1:
            raise RuntimeError(f'Release Core object is missing/stale: {source.name}; ask root to finish its build')
    return objects


def run_native(command, environment, log_path):
    started = time.monotonic()
    peak_sample = 0
    reason = None
    with log_path.open('w') as log:
        child = subprocess.Popen(command, cwd=PROJECT, env=environment, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        while True:
            pid, status, usage = os.wait4(child.pid, os.WNOHANG)
            if pid == child.pid:
                child.returncode = os.waitstatus_to_exitcode(status)
                break
            try:
                sample = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(child.pid)],
                                        capture_output=True, text=True, timeout=2)
                if sample.stdout.strip():
                    peak_sample = max(peak_sample, int(sample.stdout.strip()) * 1024)
            except (ValueError, subprocess.TimeoutExpired):
                pass
            if time.monotonic() - started > 180:
                reason = 'Native fixture exceeded the 180s watchdog'
            if peak_sample > RSS_LIMIT:
                reason = 'Native fixture exceeded the 512 MiB RSS watchdog'
            if reason:
                # This is the exact isolated test process group, never the user app.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                _, status, usage = os.wait4(child.pid, 0)
                child.returncode = os.waitstatus_to_exitcode(status)
                break
            time.sleep(0.1)
    native_peak = int(usage.ru_maxrss) * (1 if sys.platform == 'darwin' else 1024)
    if native_peak > RSS_LIMIT and reason is None:
        reason = 'Exact native-process peak exceeded 512 MiB'
    return {'exitCode': child.returncode, 'nativePeakRSSBytes': native_peak,
            'sampledPeakRSSBytes': peak_sample, 'wallSeconds': time.monotonic() - started,
            'rssLimitBytes': RSS_LIMIT, 'watchdogFailure': reason}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=pathlib.Path,
                        default=PROJECT / '.build' / (platform.machine() + '-apple-macosx') / 'release')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    output = (args.output or PROJECT / 'analysis' / ('task-lifecycle-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = {'passed': False, 'executed': False, 'parseOnly': args.parse_only,
                'swiftPMInvoked': False, 'userAppControlled': False, 'scannerStubbed': False,
                'progressCallbackGate': True, 'duplicateFiles': DUPLICATES,
                'uniqueSparseFileBytes': LARGE_BYTES, 'sources': {},
                'boundaries': ['owned fake home only', 'no cleanup/restore/real maintenance',
                               'privacy uses owned storage/home', 'ClamAV uses injected status probe',
                               'initial SystemInfo snapshot is read-only; real history load is skipped']}
    try:
        with owned_fixture() as (root, nonce):
            sources = root / 'sources'
            originals = prepare_sources(sources)
            manifest['sources'] = {name + '.swift': hashlib.sha256(text.encode()).hexdigest() for name, text in originals.items()}
            manifest['fixtureRemovedAfterRun'] = True
            paths = sorted(sources.glob('*.swift'))
            subprocess.run(['swiftc', '-frontend', '-parse', *map(str, paths)], cwd=PROJECT, check=True, timeout=60)
            manifest['sourceAnchorsValidated'] = True; manifest['parsePassed'] = True
            if args.parse_only:
                write_json(output / 'manifest.json', manifest)
                print(f'PASS syntax/source anchors only; native execution not run: {output}')
                return
            objects = release_objects(args.binary_dir.resolve())
            home = create_files(root)
            executable = root / 'TaskLifecycleChecks'
            command = ['swiftc', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0',
                       '-parse-as-library', '-I', str(args.binary_dir.resolve() / 'Modules'),
                       '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3',
                       *map(str, paths), *map(str, objects), '-o', str(executable)]
            with (output / 'compile.log').open('w') as log:
                subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            manifest['executed'] = True
            environment = os.environ.copy(); environment['TMPDIR'] = str(root / 'runtime') + '/'
            measurement = run_native([str(executable), str(output / 'lifecycle-results.json'), str(home), nonce],
                                     environment, output / 'native.log')
            manifest.update(measurement)
            result_path = output / 'lifecycle-results.json'
            manifest['passed'] = measurement['exitCode'] == 0 and measurement['watchdogFailure'] is None and result_path.exists() and json.loads(result_path.read_text()).get('passed') is True
            write_json(output / 'manifest.json', manifest)
            if not manifest['passed']:
                raise RuntimeError(f'Native lifecycle regression failed; inspect {output / "native.log"}')
            print(f'PASS isolated real UI/scan lifecycle: {result_path}')
    except Exception as error:
        manifest['error'] = str(error); write_json(output / 'manifest.json', manifest)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'FAIL {error}', file=sys.stderr)
        raise SystemExit(1)
