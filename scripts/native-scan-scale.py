#!/usr/bin/env python3
"""Measure a real AppState/MainView duplicate scan in an isolated native process.

No SwiftPM invocation. Uses an existing release Core build, a temporary copy of
production GUI sources, and 12001 owned identical 64-byte files. Native checks
use geometry, never Vision/OCR or desktop screenshots. wait4(exact_pid) measures
the whole native test process including AppKit, SwiftUI, the scan and pagination.

  python3 scripts/native-scan-scale.py --binary-dir .build/arm64-apple-macosx/release
"""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import platform
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

PROJECT = pathlib.Path(__file__).resolve().parent.parent
FILE_COUNT = 12001
FILE_BYTES = 64
RSS_LIMIT = 512 * 1024 * 1024
TIME_LIMIT = 180.0


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


@contextlib.contextmanager
def owned_fixture_directory(base):
    directory = base / str(uuid.uuid4())
    directory.mkdir(mode=0o700)
    try:
        yield directory
    finally:
        shutil.rmtree(directory)


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f'Production anchor changed: {before[:100]}')
    return source.replace(before, after, 1)


def replace_method(source, start, end, replacement):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f'Production method boundaries changed: {start}')
    prefix, remainder = source.split(start, 1)
    _, suffix = remainder.split(end, 1)
    return prefix + replacement + end + suffix


def prepare_sources(directory):
    directory.mkdir(parents=True, exist_ok=True)
    state = (PROJECT / 'Sources/CleanRoomMac/AppState.swift').read_text()
    state = replace_once(state, '        reloadHistory()\n', '        // Isolated benchmark: skip real history initialization.\n')
    state = replace_once(state, 'private func setRoots(', 'func setRoots(')
    state = replace_once(state, 'let options = ScanOptions(roots:', 'let options = ScanOptions(home: NativeScanFixture.home, roots:')
    # Only the temporary copy disables actions which the measurement must never
    # invoke. Real scanning, mailbox, disk pages, sorting and selection are intact.
    for start, end, replacement in [
        ('    func chooseRoots() {', '\n    func resetRoots()', '    func chooseRoots() { preconditionFailure("Native benchmark forbids file dialogs") }\n'),
        ('    func trashSelected() {', '\n    func reloadHistory()', '    func trashSelected() { preconditionFailure("Native benchmark forbids cleanup") }\n'),
        ('    func reloadHistory() {', '\n    func olderHistory()', '    func reloadHistory() { preconditionFailure("Native benchmark forbids real history reads") }\n'),
        ('    func olderHistory() {', '\n    func newerHistory()', '    func olderHistory() { preconditionFailure("Native benchmark forbids real history reads") }\n'),
        ('    func newerHistory() {', '\n    func restore(', '    func newerHistory() { preconditionFailure("Native benchmark forbids real history reads") }\n'),
        ('    func restore(_ record: TrashRecord) {', '\n    func reveal(', '    func restore(_ record: TrashRecord) { preconditionFailure("Native benchmark forbids restoring files") }\n'),
        ('    func reveal(_ path: String) {', '\n    func openFullDiskAccessSettings()', '    func reveal(_ path: String) { preconditionFailure("Native benchmark forbids controlling Finder") }\n'),
        ('    func openFullDiskAccessSettings() {', '\n    func exportReport()', '    func openFullDiskAccessSettings() { preconditionFailure("Native benchmark forbids settings changes") }\n'),
    ]:
        state = replace_method(state, start, end, replacement)
    prefix, suffix = state.split('    func exportReport() {', 1)
    if not suffix.rstrip().endswith('}\n}'):
        raise RuntimeError('exportReport must remain the final method for this fixture transform')
    state = prefix + '    func exportReport() { preconditionFailure("Native benchmark forbids exporting files") }\n}\n'
    (directory / 'AppState.swift').write_text(state)
    main = (PROJECT / 'Sources/CleanRoomMac/MainView.swift').read_text()
    main = replace_once(main, '.accessibilityIdentifier("scan.cleanup")', '.accessibilityIdentifier("scan.cleanup").background(NativeScaleProbe(name: "cleanup"))')
    main = replace_once(main, '.overlay(alignment: .top) { Divider() }', '.overlay(alignment: .top) { Divider() }.background(NativeScaleProbe(name: "footer"))')
    main = replace_once(main, '.overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05)))', '.overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05))).background(NativeScaleProbe(name: "list"))')
    summary = 'Text("其中 \\(state.processableItemCount) 项可逐项核对处理；选择仅限当前页。")\n                .font(.caption2).foregroundStyle(secondaryText)'
    main = replace_once(main, summary, summary + '.background(NativeScaleProbe(name: "processableSummary"))')
    (directory / 'MainView.swift').write_text(main)
    names = ['SmartCareView', 'SpaceLensView', 'OperationsView', 'MalwareView', 'MonitorView', 'AdvancedCleanupView', 'BrowserPrivacyView', 'PreferencesView']
    (directory / 'OtherDestinations.swift').write_text('import SwiftUI\n' + '\n'.join(f'struct {name}: View {{ var body: some View {{ EmptyView() }} }}' for name in names) + '\n')
    for name in ['SupportingViews.swift', 'PermissionGuideView.swift']:
        (directory / name).write_text((PROJECT / 'Sources/CleanRoomMac' / name).read_text())
    (directory / 'NativeScanScaleMain.swift').write_text((PROJECT / 'Tests/NativeScanScaleChecks/main.swift').read_text())
    return sorted(directory.glob('*.swift'))


def run_exact_pid(command, environment, log_path):
    started = time.monotonic()
    sampled_peak = samples = 0
    reason = None
    child = None
    usage = None
    with log_path.open('wb') as log:
        try:
            child = subprocess.Popen(command, stdout=log, stderr=log, env=environment, cwd=PROJECT, start_new_session=True)
            while True:
                waited_pid, status, current_usage = os.wait4(child.pid, os.WNOHANG)
                if waited_pid == child.pid:
                    usage = current_usage
                    child.returncode = os.waitstatus_to_exitcode(status)
                    break
                elapsed = time.monotonic() - started
                if reason is None and elapsed >= TIME_LIMIT:
                    reason = 'wall-time-180s'
                if reason is None:
                    sample = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(child.pid)], capture_output=True, text=True, timeout=1, check=False)
                    value = sample.stdout.strip()
                    if value.isdigit():
                        samples += 1
                        sampled_peak = max(sampled_peak, int(value) * 1024)
                        if sampled_peak > RSS_LIMIT:
                            reason = 'rss-512MiB'
                if reason is not None:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                time.sleep(0.01 if reason else 0.10)
        except BaseException:
            if child is not None and child.returncode is None:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                try:
                    _, status, usage = os.wait4(child.pid, 0)
                    child.returncode = os.waitstatus_to_exitcode(status)
                except ChildProcessError: pass
            raise
    raw_peak = usage.ru_maxrss
    peak = int(raw_peak if sys.platform == 'darwin' else raw_peak * 1024)
    return {'pid': child.pid, 'exitCode': child.returncode, 'wallSeconds': time.monotonic() - started,
            'peakRSSBytes': peak, 'rawMaxRSS': raw_peak, 'rawMaxRSSUnit': 'bytes' if sys.platform == 'darwin' else 'KiB',
            'sampledPeakRSSBytes': sampled_peak, 'sampleCount': samples, 'watchdogReason': reason,
            'userCPUSeconds': usage.ru_utime, 'systemCPUSeconds': usage.ru_stime,
            'measurement': 'wait4(exact test PID); entire AppKit/SwiftUI/scanner/pagination process; no Vision/OCR; no RUSAGE_CHILDREN aggregation'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary-dir', type=pathlib.Path, default=PROJECT / f'.build/{platform.machine()}-apple-macosx/release')
    parser.add_argument('--label', default='gui-v040-native-duplicates-12001')
    parser.add_argument('--rounds', type=int, choices=range(1, 4), default=1)
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    if not args.label.startswith('gui-v040-') or any(character not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for character in args.label):
        raise RuntimeError('label must start gui-v040- and contain lowercase ASCII letters, digits or hyphens')
    output = PROJECT / 'analysis/performance'; output.mkdir(parents=True, exist_ok=True)
    prefix = output / args.label
    result_path = prefix.with_suffix('.json')
    if result_path.exists(): raise RuntimeError(f'Results already exist: {result_path}; use a new --label')
    source_dir = output / (args.label + '-sources')
    sources = prepare_sources(source_dir)
    binary_dir = args.binary_dir.resolve()
    objects = sorted((binary_dir / 'CleanRoomCore.build').glob('*.o'))
    module = binary_dir / 'Modules/CleanRoomCore.swiftmodule'
    manifest = {'createdAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'swiftPMInvoked': False, 'productionAppControlled': False, 'visionImported': False,
                'files': FILE_COUNT, 'bytesPerFile': FILE_BYTES, 'rounds': args.rounds,
                'rssLimitBytes': RSS_LIMIT, 'wallLimitSeconds': TIME_LIMIT,
                'sourceSHA256': {path.name: sha256(path) for path in sources},
                'transforms': ['skip history init', 'inject owned fixture home into ScanOptions', 'expose setRoots for owned Downloads', 'disable cleanup/history/export/dialog/Finder/settings methods', 'background geometry probes', 'stub unrendered destinations'],
                'coreBinaryDirectory': str(binary_dir)}
    if args.parse_only:
        subprocess.run(['swiftc', '-frontend', '-parse', *map(str, sources)], cwd=PROJECT, check=True, timeout=60)
        manifest['parseOnly'] = True
        write_json(prefix.with_suffix('.manifest.json'), manifest)
        print('PASS native fixture syntax; measurement not run')
        return
    if not objects or not module.exists(): raise RuntimeError('Complete the main release Core build first; this script never invokes SwiftPM')
    manifest['coreModuleSHA256'] = sha256(module)
    manifest['coreObjectsSHA256'] = {path.name: sha256(path) for path in objects}
    result = {'manifest': manifest, 'passed': False}
    fixture_base = PROJECT / '.perf-ui-fixtures'
    fixture_base.mkdir(exist_ok=True)
    with owned_fixture_directory(fixture_base) as temporary:
        scratch = temporary.resolve()
        home, runtime = scratch / 'home', scratch / 'runtime-temp'
        downloads = home / 'Downloads'
        downloads.mkdir(parents=True); runtime.mkdir(mode=0o700)
        nonce = str(uuid.uuid4())
        write_json(scratch / 'fixture-owner.json', {'kind': 'AIYOUClean.NativeScanScaleFixture', 'nonce': nonce, 'count': FILE_COUNT})
        payload = b'AIYOUClean native duplicate fixture v0.4.0\n'.ljust(FILE_BYTES, b'0')
        assert len(payload) == FILE_BYTES
        for index in range(FILE_COUNT):
            with (downloads / f'entry-{index:05d}.bin').open('xb') as handle: handle.write(payload)
        manifest['fixturePayloadSHA256'] = hashlib.sha256(payload).hexdigest()
        manifest['fixtureHome'] = str(home)
        executable = scratch / 'NativeScanScaleChecks'
        command = ['swiftc', '-O', '-whole-module-optimization', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3', *map(str, sources), *map(str, objects), '-o', str(executable)]
        with prefix.with_suffix('.build.log').open('wb') as log:
            subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
        if manifest['coreModuleSHA256'] != sha256(module) or manifest['coreObjectsSHA256'] != {path.name: sha256(path) for path in objects}:
            raise RuntimeError('Core objects changed during isolated linking; rerun after the shared build finishes')
        manifest['nativeTestBinarySHA256'] = sha256(executable)
        native_path = prefix.with_suffix('.native.json')
        environment = dict(os.environ)
        process = run_exact_pid([str(executable), str(native_path), str(home), str(runtime), str(FILE_COUNT), str(args.rounds), nonce], environment, prefix.with_suffix('.log'))
        result['process'] = process
        if native_path.exists(): result['native'] = json.loads(native_path.read_text())
        result['checks'] = {'nativeChecksPassed': result.get('native', {}).get('passed') is True,
                            'exitZero': process['exitCode'] == 0, 'watchdogNotTriggered': process['watchdogReason'] is None,
                            'peakRSSWithin512MiB': process['peakRSSBytes'] <= RSS_LIMIT, 'wallWithin180Seconds': process['wallSeconds'] <= TIME_LIMIT}
        result['passed'] = all(result['checks'].values())
        owned_fixture_path = str(scratch)
    result['fixtureCleaned'] = not pathlib.Path(owned_fixture_path).exists()
    result['passed'] = result['passed'] and result['fixtureCleaned']
    write_json(prefix.with_suffix('.manifest.json'), manifest)
    write_json(result_path, result)
    print(json.dumps({'passed': result['passed'], 'peakRSSMiB': result['process']['peakRSSBytes'] / 1024 / 1024, 'wallSeconds': result['process']['wallSeconds'], 'fixtureCleaned': result['fixtureCleaned'], 'result': str(result_path)}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    try: raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f'FAIL isolated compiler/check command ({error.returncode}); inspect analysis/performance/gui-v040-*.build.log', file=sys.stderr)
        raise SystemExit(error.returncode)
