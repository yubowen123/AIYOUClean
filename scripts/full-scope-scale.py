#!/usr/bin/env python3
"""Real SmartCare -> FullDiskFileScanner GUI completeness/RSS fixture (no SwiftPM).

The UI default is checked, then only selectedFolders=[owned fake home] is scanned.
12001 identical 64-byte files span Documents/Desktop/Movies/Custom; a unique
101000000-byte sparse file is owner-write-only so erroneous content hashing fails.
The four read-only system-security commands may run; their success is not asserted.

  python3 scripts/full-scope-scale.py --binary-dir .build/arm64-apple-macosx/release

Evidence/source snapshots: analysis/performance/full-scope-v050-*. The measured
native process imports no Vision, captures no screenshots, and cannot clean files.
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
DUPLICATE_FILES = 12001
FILE_BYTES = 64
LARGE_BYTES = 101_000_000
DIRECTORIES = ['Documents', 'Desktop', 'Movies', 'Custom']
RSS_LIMIT = 512 * 1024 * 1024
TIME_LIMIT = 180.0


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


@contextlib.contextmanager
def owned_directory():
    base = PROJECT / '.perf-ui-fixtures'; base.mkdir(exist_ok=True)
    directory = base / str(uuid.uuid4()); directory.mkdir(mode=0o700)
    try: yield directory
    finally: shutil.rmtree(directory)


def replace_once(source, before, after):
    if source.count(before) != 1: raise RuntimeError(f'Production anchor changed: {before[:100]}')
    return source.replace(before, after, 1)


def replace_method(source, start, end, replacement):
    if source.count(start) != 1 or source.count(end) != 1: raise RuntimeError(f'Production method boundaries changed: {start}')
    prefix, remainder = source.split(start, 1)
    _, suffix = remainder.split(end, 1)
    return prefix + replacement + end + suffix


def prepare_sources(directory):
    directory.mkdir(parents=True, exist_ok=True)
    original = (PROJECT / 'Sources/CleanRoomMac/SmartCareView.swift').read_text()
    source = replace_once(original, 'private final class SmartCareViewState:', 'final class SmartCareViewState:')
    source = replace_once(source, 'private enum SmartCareResultMode:', 'enum SmartCareResultMode:')
    source = replace_once(source, 'private struct SmartCareConfirmation:', 'struct SmartCareConfirmation:')
    source = replace_once(source, '    @StateObject private var state = SmartCareViewState()', '''    @ObservedObject private var state: SmartCareViewState
    init(measurementState: SmartCareViewState) { self.state = measurementState }''')
    source = replace_once(source, '    func resume() { presentationActive = true }', '''    func resume() { presentationActive = true }
    func useOwnedFixtureRoot(_ root: URL) {
        precondition(!busy && scanScope == .selectedFolders && root.path == FullScopeFixture.home.path)
        roots = [root]
    }''')
    source = replace_once(source, '        let options = SmartCareOptions(includeApplications:', '''        precondition(scanScope == .selectedFolders && roots.count == 1 && roots[0].path == FullScopeFixture.home.path, "Benchmark must never scan real disks or the real home")
        let options = SmartCareOptions(home: FullScopeFixture.home, includeApplications:''')
    source = replace_method(source, '    func chooseRoots() {', '\n    func modeCount(', '    func chooseRoots() { preconditionFailure("Full-scope benchmark forbids file dialogs") }\n')
    source = replace_method(source, '    func trash(_ pending: SmartCareConfirmation) {', '\n    private func finish(', '    func trash(_ pending: SmartCareConfirmation) { preconditionFailure("Full-scope benchmark forbids cleanup") }\n')
    for before, after in [
        ('                    candidateSummary(report)', '                    candidateSummary(report).background(FullScopeProbe(name: "summary"))'),
        ('                    resultModePicker\n', '                    resultModePicker.background(FullScopeProbe(name: "modes"))\n'),
        ('                    candidateList(report)', '                    candidateList(report).background(FullScopeProbe(name: "list"))'),
        ('if let report = state.report { actionBar(report) }', 'if let report = state.report { actionBar(report).background(FullScopeProbe(name: "footer")) }'),
    ]: source = replace_once(source, before, after)
    cleanup = 'Button("清理所选…") { state.requestTrash() }.buttonStyle(.borderedProminent).tint(smartAccent).disabled(state.busy || state.selected.isEmpty || report.invalidated)'
    source = replace_once(source, cleanup, cleanup + '.background(FullScopeProbe(name: "cleanup"))')
    assert source.count('SmartCareService().scan(') == 1
    assert 'Scanner().scan(' not in source and 'TrashManager().trash(' not in source and 'AppState' not in source
    (directory / 'SmartCareView.swift').write_text(source)
    main = (PROJECT / 'Sources/CleanRoomMac/MainView.swift').read_text()
    heading = main[main.index('struct PageHeading: View {'):main.index('struct DashboardView: View {')]
    palette = '\n'.join(line for line in main.splitlines() if line.startswith('private let accent =') or line.startswith('private let secondaryText ='))
    (directory / 'PageHeading.swift').write_text('import SwiftUI\n' + palette + '\n' + heading)
    (directory / 'PermissionGuideView.swift').write_text((PROJECT / 'Sources/CleanRoomMac/PermissionGuideView.swift').read_text())
    (directory / 'FullScopeMain.swift').write_text((PROJECT / 'Tests/FullScopeScaleChecks/main.swift').read_text())
    return sorted(directory.glob('*.swift')), hashlib.sha256(original.encode()).hexdigest()


def run_exact_pid(command, log_path):
    start = time.monotonic(); sampled_peak = samples = 0; reason = None; child = None
    with log_path.open('wb') as log:
        try:
            child = subprocess.Popen(command, cwd=PROJECT, stdout=log, stderr=log, env=dict(os.environ), start_new_session=True)
            while True:
                try: waited, status, usage = os.wait4(child.pid, os.WNOHANG)
                except InterruptedError: continue
                if waited == child.pid:
                    child.returncode = os.waitstatus_to_exitcode(status); break
                if reason is None and time.monotonic() - start >= TIME_LIMIT: reason = 'wall-time-180s'
                if reason is None:
                    try:
                        sample = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(child.pid)], capture_output=True, text=True, timeout=0.5, check=False)
                        value = sample.stdout.strip()
                        if value.isdigit():
                            samples += 1; sampled_peak = max(sampled_peak, int(value) * 1024)
                            if sampled_peak > RSS_LIMIT: reason = 'rss-512MiB'
                    except subprocess.TimeoutExpired: pass
                if reason is None and time.monotonic() - start >= TIME_LIMIT: reason = 'wall-time-180s'
                if reason:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                time.sleep(0.01 if reason else 0.10)
        except BaseException:
            if child is not None and child.returncode is None:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                try:
                    _, status, usage = os.wait4(child.pid, 0); child.returncode = os.waitstatus_to_exitcode(status)
                except ChildProcessError: pass
            raise
    peak = int(usage.ru_maxrss if sys.platform == 'darwin' else usage.ru_maxrss * 1024)
    return {'pid': child.pid, 'exitCode': child.returncode, 'wallSeconds': time.monotonic() - start,
            'peakRSSBytes': peak, 'rawMaxRSS': usage.ru_maxrss, 'rawMaxRSSUnit': 'bytes' if sys.platform == 'darwin' else 'KiB',
            'sampledPeakRSSBytes': sampled_peak, 'sampleCount': samples, 'watchdogReason': reason,
            'userCPUSeconds': usage.ru_utime, 'systemCPUSeconds': usage.ru_stime,
            'measurement': 'wait4(exact native PID); AppKit/SwiftUI + real SmartCare + FullDiskFileScanner + pagination; no Vision/OCR/bitmap capture; no manual aggregation of separate security-command PIDs'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary-dir', type=pathlib.Path, default=PROJECT / f'.build/{platform.machine()}-apple-macosx/release')
    parser.add_argument('--label', default='full-scope-v050-real-gui-12001')
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    if not args.label.startswith('full-scope-v050-') or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in args.label): raise RuntimeError('Use a full-scope-v050- lowercase ASCII label')
    output = PROJECT / 'analysis/performance'; output.mkdir(parents=True, exist_ok=True)
    prefix = output / args.label
    if prefix.with_suffix('.json').exists(): raise RuntimeError('Evidence already exists; use a new --label')
    sources, production_hash = prepare_sources(output / (args.label + '-sources'))
    binary_dir = args.binary_dir.resolve(); objects = sorted((binary_dir / 'CleanRoomCore.build').glob('*.o')); module = binary_dir / 'Modules/CleanRoomCore.swiftmodule'
    manifest = {'createdAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'pipeline': 'SmartCareViewState.scan -> SmartCareService -> FullDiskFileScanner',
                'legacyScannerEntryPointUsed': False, 'swiftPMInvoked': False, 'productionAppControlled': False, 'visionImported': False,
                'uiDefaultMustBeAllLocalDisks': True, 'measuredScope': 'selectedFolders with owned fake home only',
                'duplicateFiles': DUPLICATE_FILES, 'bytesPerDuplicate': FILE_BYTES, 'directories': DIRECTORIES,
                'uniqueSparseLogicalBytes': LARGE_BYTES, 'uniqueSparseMode': '0200 (owner-write-only)',
                'securityCommands': 'four read-only Core commands allowed; success not asserted',
                'rssLimitBytes': RSS_LIMIT, 'wallLimitSeconds': TIME_LIMIT,
                'productionSmartCareViewSHA256': production_hash, 'sourceSHA256': {p.name: sha256(p) for p in sources}, 'runnerSHA256': sha256(pathlib.Path(__file__)),
                'transforms': ['expose state and mode type', 'ObservedObject uses the exact tested state', 'inject fake home into SmartCareOptions', 'require selectedFolders=[owned home]', 'forbid cleanup/dialog actions', 'geometry probes'],
                'coreBinaryDirectory': str(binary_dir)}
    write_json(prefix.with_suffix('.manifest.json'), manifest)
    if args.parse_only:
        subprocess.run(['swiftc', '-frontend', '-parse', *map(str, sources)], cwd=PROJECT, check=True, timeout=60)
        print('PASS full-scope harness syntax; no scan/build/measurement run'); return 0
    if not objects or not module.exists() or not any(p.name == 'FullDiskFileScanner.swift.o' for p in objects): raise RuntimeError('Wait for the stable v0.5 Core release objects; this script never invokes SwiftPM')
    manifest['coreModuleSHA256'] = sha256(module); manifest['coreObjectsSHA256'] = {p.name: sha256(p) for p in objects}
    result = {'manifest': manifest, 'passed': False}
    with owned_directory() as scratch:
        home = scratch / 'home'
        for directory in DIRECTORIES: (home / directory).mkdir(parents=True)
        payload = b'AIYOUClean full-scope fixture v0.5.0\n'.ljust(FILE_BYTES, b'0'); assert len(payload) == FILE_BYTES
        digest = hashlib.sha256(payload).hexdigest(); nonce = str(uuid.uuid4())
        for index in range(DUPLICATE_FILES):
            with (home / DIRECTORIES[index % 4] / f'copy-{index:05d}.bin').open('xb') as handle: handle.write(payload)
        large = home / 'Custom/unique-large.bin'
        with large.open('xb') as handle: handle.truncate(LARGE_BYTES)
        large.chmod(0o200)
        manifest['uniqueSparseAllocatedBytes'] = large.stat().st_blocks * 512
        manifest['fixtureHome'] = str(home); manifest['duplicatePayloadSHA256'] = digest
        write_json(scratch / 'fixture-owner.json', {'kind': 'AIYOUClean.FullScopeScaleFixture', 'nonce': nonce, 'count': DUPLICATE_FILES, 'bytes': FILE_BYTES, 'largeBytes': LARGE_BYTES, 'sha256': digest})
        executable = scratch / 'FullScopeScaleChecks'
        command = ['swiftc', '-O', '-whole-module-optimization', '-j', '2', '-target', platform.machine() + '-apple-macosx13.0', '-parse-as-library', '-I', str(binary_dir / 'Modules'), '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3', *map(str, sources), *map(str, objects), '-o', str(executable)]
        with prefix.with_suffix('.build.log').open('wb') as log: subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
        if manifest['coreModuleSHA256'] != sha256(module) or manifest['coreObjectsSHA256'] != {p.name: sha256(p) for p in objects}: raise RuntimeError('Core changed during linking; rerun after the release build stabilizes')
        manifest['nativeTestBinarySHA256'] = sha256(executable)
        native_path = prefix.with_suffix('.native.json')
        result['process'] = run_exact_pid([str(executable), str(native_path), str(home), nonce], prefix.with_suffix('.log'))
        if native_path.exists(): result['native'] = json.loads(native_path.read_text())
        process = result['process']
        result['checks'] = {'nativePassed': result.get('native', {}).get('passed') is True, 'exitZero': process['exitCode'] == 0,
                            'peakWithin512MiB': process['peakRSSBytes'] <= RSS_LIMIT, 'wallWithin180s': process['wallSeconds'] <= TIME_LIMIT, 'watchdogNotTriggered': process['watchdogReason'] is None}
        result['passed'] = all(result['checks'].values()); fixture_path = scratch
    result['fixtureCleaned'] = not fixture_path.exists(); result['passed'] = result['passed'] and result['fixtureCleaned']
    write_json(prefix.with_suffix('.manifest.json'), manifest); write_json(prefix.with_suffix('.json'), result)
    print(json.dumps({'passed': result['passed'], 'peakRSSMiB': result['process']['peakRSSBytes'] / 1024 / 1024, 'wallSeconds': result['process']['wallSeconds'], 'fixtureCleaned': result['fixtureCleaned'], 'result': str(prefix.with_suffix('.json'))}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    try: raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f'FAIL isolated compiler/check ({error.returncode}); inspect full-scope-v050-*.build.log', file=sys.stderr); raise SystemExit(error.returncode)
