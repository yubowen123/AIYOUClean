#!/usr/bin/env python3
"""Benchmark actual SmartCare merge against existing release SQLite objects.

Release Core hides the provider seam. A private copy of SmartCare.swift exposes
that existing seam in this executable; only its UNUSED default provider is
replaced by a fail-closed stub. All merge code and Store execution remain real.
"""
import argparse, hashlib, json, math, os, pathlib, platform, shutil, signal, subprocess, tempfile, time, uuid
PROJECT = pathlib.Path(__file__).resolve().parent.parent


def store_reference(path):
    """Parse only an observed, exact results-store path; never resolve links."""
    if not path.startswith('/') or '\0' in path or len(path.encode()) > 32768:
        return None
    if any(part in ('.', '..') for part in path.split('/')):
        return None
    value = pathlib.PurePosixPath(path)
    if str(value) != path or value.name != 'results.sqlite3':
        return None
    prefix = 'AIYOUClean-results-'
    if not value.parent.name.startswith(prefix):
        return None
    session = value.parent.name[len(prefix):]
    try:
        if str(uuid.UUID(session)).upper() != session:
            return None
    except ValueError:
        return None
    return {'path': path, 'sessionID': session}


def collect_owned_stores(pid, references, errors, run=subprocess.run):
    """The unreaped Popen child owns this PID; never enumerate other sessions."""
    try:
        result = run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-nP', '-Fpn'],
                     capture_output=True, text=True, timeout=2)
        if result.returncode not in (0, 1):
            raise RuntimeError('lsof exit ' + str(result.returncode) + ': ' + result.stderr[:1000])
        observed_pid = None
        for line in result.stdout.splitlines():
            if line.startswith('p'):
                observed_pid = line[1:]
            elif line.startswith('n') and observed_pid == str(pid):
                reference = store_reference(line[1:])
                if reference is not None:
                    if len(references) >= 1024 and reference['path'] not in references:
                        raise RuntimeError('Owned-store tracking exceeded 1024 references')
                    references[reference['path']] = reference
    except Exception as error:
        text = str(error)
        if text not in errors and len(errors) < 32:
            errors.append(text)


def save_owned_stores(path, pid, references, errors):
    payload = {'kind': 'AIYOUClean.SmartMergeOwnedStores', 'childPID': pid,
               'references': list(references.values()), 'trackingErrors': list(errors),
               'collectedAtUnix': time.time(), 'collector': 'lsof exact unreaped Popen child PID'}
    with tempfile.NamedTemporaryFile('w', prefix=path.name + '.', suffix='.tmp',
                                     dir=path.parent, delete=False) as handle:
        temporary = pathlib.Path(handle.name)
        try:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write('\n'); handle.flush()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def cleanup_owned_stores(executable, owned_path, environment):
    try:
        native = subprocess.run([str(executable), '--cleanup-owned-refs', str(owned_path)],
                                cwd=PROJECT, env=environment, capture_output=True, text=True, timeout=60)
        report = json.loads(native.stdout)
        report['nativeExitCode'] = native.returncode
        report['stderr'] = native.stderr[:4000]
        report['referencesFile'] = str(owned_path)
        report['passed'] = native.returncode == 0 and report.get('passed') is True
        return report
    except Exception as error:
        return {'passed': False, 'operation': 'cleanup-owned-refs', 'error': str(error),
                'referencesFile': str(owned_path)}


def cleanup_only(args, out):
    """Compile only the public-API cleanup entry, without creating input stores."""
    binary = args.binary_dir.resolve()
    base = PROJECT / '.test-fixtures'; base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='smart-merge-cleanup-', dir=base) as temporary:
        executable = pathlib.Path(temporary) / 'SmartMergeCleanup'
        command = ['swiftc', '-O', '-j', '2', '-parse-as-library', '-D', 'MERGE_CLEANUP_ONLY',
                   '-target', platform.machine() + '-apple-macosx13.0', '-I', str(binary / 'Modules'),
                   '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3',
                   str(PROJECT / 'Tests/SmartMergeScaleChecks/main.swift'),
                   *map(str, sorted((binary / 'CleanRoomCore.build').glob('*.o'))), '-o', str(executable)]
        with (out / (args.label + '-cleanup-compile.log')).open('w') as log:
            subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        report = cleanup_owned_stores(executable, args.cleanup_owned_refs.resolve(), os.environ.copy())
        (out / (args.label + '-cleanup.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report['passed'] else 1


def run_tracked_benchmark(executable, arguments, environment, out, label, max_seconds):
    references, errors = {}, []
    owned_path = out / (label + '-owned-stores.json')
    if owned_path.exists():
        shutil.copyfile(owned_path, out / (label + '-owned-stores-previous-' + str(uuid.uuid4()) + '.json'))
    child = None
    reaped = False
    status = usage = None
    started = time.monotonic()
    finished = None
    sampled = 0
    failure = None
    cleanup = {'passed': True, 'operation': 'not-started', 'records': []}
    try:
        with (out / (label + '-native.log')).open('w') as log:
            child = subprocess.Popen(arguments, cwd=PROJECT, env=environment, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            save_owned_stores(owned_path, child.pid, references, errors)
            print('RUNNING pid=' + str(child.pid) + ' rows=' + str(arguments[-2]), flush=True)
            last_collection = -math.inf
            while True:
                pid, status, usage = os.wait4(child.pid, os.WNOHANG)
                if pid == child.pid:
                    reaped = True; finished = time.monotonic()
                    child.returncode = os.waitstatus_to_exitcode(status)
                    break
                now = time.monotonic()
                if now - last_collection >= 1:
                    collect_owned_stores(child.pid, references, errors)
                    save_owned_stores(owned_path, child.pid, references, errors)
                    last_collection = time.monotonic()
                rss = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(child.pid)],
                                     capture_output=True, text=True, timeout=2)
                if rss.stdout.strip():
                    sampled = max(sampled, int(rss.stdout.strip()) * 1024)
                if time.monotonic() - started > max_seconds or sampled > 512 * 1024 * 1024:
                    failure = str(max_seconds) + 's/512MiB watchdog'
                    # A final exact-child observation precedes termination.
                    collect_owned_stores(child.pid, references, errors)
                    save_owned_stores(owned_path, child.pid, references, errors)
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    _, status, usage = os.wait4(child.pid, 0)
                    reaped = True; finished = time.monotonic()
                    child.returncode = os.waitstatus_to_exitcode(status)
                    break
                time.sleep(0.1)
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        if child is not None:
            # Never remove a database while our worker might still use it.
            # An unreaped child PID cannot have been recycled for another app.
            if not reaped:
                try:
                    pid, status, usage = os.wait4(child.pid, os.WNOHANG)
                    if pid == 0:
                        collect_owned_stores(child.pid, references, errors)
                        save_owned_stores(owned_path, child.pid, references, errors)
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        _, status, usage = os.wait4(child.pid, 0)
                    reaped = True; finished = time.monotonic()
                    child.returncode = os.waitstatus_to_exitcode(status)
                except ChildProcessError:
                    # Do not inspect or signal a PID after losing child ownership.
                    errors.append('Child already reaped unexpectedly; no further PID inspection')
                    finished = time.monotonic()
            save_owned_stores(owned_path, child.pid, references, errors)
            # The same executable and environment derive the same canonical
            # private-temp namespace. This finishes before TemporaryDirectory
            # removes the fixture or its cleanup executable.
            cleanup = cleanup_owned_stores(executable, owned_path, environment)
            cleanup['trackedReferenceCount'] = len(references)
            cleanup['trackingErrors'] = list(errors)
            (out / (label + '-cleanup.json')).write_text(json.dumps(cleanup, ensure_ascii=False, indent=2) + '\n')
    return {'pid': child.pid if child is not None else None,
            'wallSeconds': (finished or time.monotonic()) - started,
            'peakRSSBytes': int(usage.ru_maxrss) * (1 if platform.system() == 'Darwin' else 1024) if usage else None,
            'sampledPeakRSSBytes': sampled,
            'exitCode': os.waitstatus_to_exitcode(status) if status is not None else None,
            'watchdog': failure, 'maxSeconds': max_seconds, 'ownedStoresFile': str(owned_path),
            'cleanup': cleanup, 'cleanupPassed': cleanup.get('passed') is True and not errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rows', type=int, default=30_000)
    parser.add_argument('--detail-repeat', type=int, default=114, help='Default114 preserves baseline payload; 4 gives72B for 1m stress')
    parser.add_argument('--max-seconds', type=float, default=180, help='Native process watchdog; use600 for the explicit 1m stress case')
    parser.add_argument('--label', default='baseline-30k')
    parser.add_argument('--output-dir', type=pathlib.Path, default=PROJECT / 'analysis/merge-v061')
    parser.add_argument('--binary-dir', type=pathlib.Path, default=PROJECT / '.build' / (platform.machine() + '-apple-macosx') / 'release')
    parser.add_argument('--snapshot', type=pathlib.Path)
    parser.add_argument('--cleanup-owned-refs', type=pathlib.Path, help='Only clean this explicit JSON ref list via ScanResultStore.remove; do not benchmark')
    args = parser.parse_args()
    if not math.isfinite(args.max_seconds) or args.max_seconds <= 0:
        parser.error('--max-seconds must be finite and positive')
    if not args.label or pathlib.Path(args.label).name != args.label or args.label in ('.', '..'):
        parser.error('--label must be a single file-name component')
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    if args.cleanup_owned_refs is not None:
        raise SystemExit(cleanup_only(args, out))
    snapshot = (args.snapshot or out / 'baseline-core-snapshot').resolve()
    if not snapshot.exists():
        snapshot.mkdir(mode=0o700)
        shutil.copytree(args.binary_dir / 'CleanRoomCore.build', snapshot / 'CleanRoomCore.build')
        shutil.copytree(args.binary_dir / 'Modules', snapshot / 'Modules')
        shutil.copyfile(PROJECT / 'Sources/CleanRoomCore/SmartCare.swift', snapshot / 'SmartCare.swift')
    hashes = {}
    selected = list((snapshot / 'CleanRoomCore.build').glob('*.o')) + list((snapshot / 'Modules').glob('CleanRoomCore.*')) + [snapshot / 'SmartCare.swift']
    for path in selected:
        if path.is_file():
            hashes[str(path.relative_to(snapshot))] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}
    (out / (snapshot.name + '-hashes.json')).write_text(json.dumps(hashes, indent=2, sort_keys=True) + '\n')
    source = (snapshot / 'SmartCare.swift').read_text()
    default_start = source.index('private struct SmartCareDefaultProvider:')
    default_end = source.index('public final class SmartCareService:', default_start)
    # Keep the service, options, progress and merge bodies byte-for-byte.
    source = source[:default_start] + '''private struct SmartCareDefaultProvider: SmartCareScanProviding {
    func scan(_ kind: ScanKind, options: ScanOptions, cancellation: MalwareCancellation, deadline: TimeInterval, progress: @escaping @Sendable (Int, String) -> Void) -> ScanReport {
        fatalError("Scale harness requires generated metadata provider")
    }
}
''' + source[default_end:]
    base = PROJECT / '.test-fixtures'; base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='smart-merge-' + str(uuid.uuid4()) + '-', dir=base) as temp:
        fixture = pathlib.Path(temp); (fixture / 'runtime').mkdir(mode=0o700)
        (fixture / 'SmartCare.swift').write_text('import CleanRoomCore\n' + source)
        shutil.copyfile(PROJECT / 'Tests/SmartMergeScaleChecks/main.swift', fixture / 'main.swift')
        executable = fixture / 'SmartMergeScale'
        command = ['swiftc', '-O', '-j', '2', '-parse-as-library', '-module-name', 'SmartMergeScale',
                   '-target', platform.machine() + '-apple-macosx13.0', '-I', str(snapshot / 'Modules'),
                   '-I', str(PROJECT / 'Sources/CSQLite'), '-lsqlite3', str(fixture / 'SmartCare.swift'),
                   str(fixture / 'main.swift'), *map(str, sorted((snapshot / 'CleanRoomCore.build').glob('*.o'))), '-o', str(executable)]
        with (out / (args.label + '-compile.log')).open('w') as log:
            subprocess.run(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        env = os.environ.copy(); env['TMPDIR'] = str(fixture / 'runtime') + '/'
        result_path = out / (args.label + '.json')
        measured = run_tracked_benchmark(executable,
                    [str(executable), str(result_path), str(fixture), str(args.rows), str(args.detail_repeat)],
                    env, out, args.label, args.max_seconds)
        measured.update({'rows': args.rows, 'swiftPMInvoked': False,
                         'smartCareSourceSHA256': hashlib.sha256((snapshot / 'SmartCare.swift').read_bytes()).hexdigest(),
                         'mergeStubbed': False, 'unusedDefaultProviderStubbed': True})
        if result_path.exists():
            native = json.loads(result_path.read_text())
            measured['benchmarkPassed'] = native.get('passed') is True
            measured.update(native)
        measured['passed'] = measured.get('benchmarkPassed') is True and measured['cleanupPassed'] and measured['watchdog'] is None
        (out / (args.label + '.json')).write_text(json.dumps(measured, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(measured, ensure_ascii=False, indent=2))
        if measured['watchdog']: raise SystemExit(2)
        # Missing merge progress is the expected RED result on the old version.
        raise SystemExit(0 if measured.get('passed') else 1)


if __name__ == '__main__':
    main()
