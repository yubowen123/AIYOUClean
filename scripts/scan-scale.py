#!/usr/bin/env python3
"""Compare cleanup scans on an owned synthetic tree; never scan the user's Home.

Example:
  python3 scripts/scan-scale.py --baseline /abs/old-cli --candidate /abs/new-cli \
      --count 120000 --label full-home-120k

The old CLI keeps its defaults. The candidate receives only --full in addition
to the shared root/output arguments. Each process is reaped with wait4(pid), so
ru_maxrss is that process's peak, not a cumulative RUSAGE_CHILDREN high-water mark.
Generated files are sparse 64-byte files, arranged in groups of at most 1000.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


PROJECT = pathlib.Path(__file__).resolve().parent.parent
RSS_LIMIT = 512 * 1024 * 1024
TIME_LIMIT = 120.0
SAMPLE_INTERVAL = 0.10
REPORT_LIMIT = 16 * 1024 * 1024
FILE_BYTES = 64
FILES_PER_DIRECTORY = 1000


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def absolute_binary(value):
    path = pathlib.Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("binary paths must be absolute")
    try:
        path = path.resolve(strict=True)
    except OSError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if not path.is_file() or not os.access(path, os.X_OK):
        raise argparse.ArgumentTypeError("binary must be a regular executable")
    return path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    # Do not silently overwrite an earlier run's evidence.
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def read_report(path):
    try:
        with path.open("rb") as handle:
            data = handle.read(REPORT_LIMIT + 1)
        if len(data) > REPORT_LIMIT:
            return None, "report exceeded 16 MiB"
        report = json.loads(data)
        if not isinstance(report, dict):
            return None, "report is not an object"
        if not isinstance(report.get("items"), list):
            return None, "report has no items array"
        if type(report.get("truncated")) is not bool:
            return None, "report has no boolean truncated state"
        if type(report.get("visitedFiles")) is not int:
            return None, "report has no integer visitedFiles count"
        return report, None
    except (OSError, ValueError) as error:
        return None, str(error)


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_child(command, environment, log_path, cwd):
    """No Popen.poll/wait: only wait4 on this exact PID may reap it."""
    started_at = utc_now()
    started = time.monotonic()
    sampled_peak = 0
    sample_count = 0
    watchdog_reason = None
    child = None
    usage = None
    status = None
    with log_path.open("xb") as log:
        try:
            child = subprocess.Popen(
                command, stdout=log, stderr=log, env=environment,
                cwd=cwd, start_new_session=True,
            )
            while True:
                try:
                    waited_pid, current_status, current_usage = os.wait4(child.pid, os.WNOHANG)
                except InterruptedError:
                    continue
                if waited_pid == child.pid:
                    status, usage = current_status, current_usage
                    child.returncode = os.waitstatus_to_exitcode(status)
                    break
                elapsed = time.monotonic() - started
                if watchdog_reason is None and elapsed >= TIME_LIMIT:
                    watchdog_reason = "wall-time-120s"
                    kill_group(child.pid)
                if watchdog_reason is None:
                    try:
                        sample = subprocess.run(
                            ["/bin/ps", "-o", "rss=", "-p", str(child.pid)],
                            capture_output=True, text=True, timeout=0.5,
                            check=False,
                        )
                        value = sample.stdout.strip()
                        if value.isdigit():
                            sample_count += 1
                            sampled_peak = max(sampled_peak, int(value) * 1024)
                            if sampled_peak > RSS_LIMIT:
                                watchdog_reason = "rss-512MiB"
                                kill_group(child.pid)
                    except subprocess.TimeoutExpired:
                        pass
                # A ps sample cannot extend the scanner's deadline unchecked.
                if watchdog_reason is None and time.monotonic() - started >= TIME_LIMIT:
                    watchdog_reason = "wall-time-120s"
                    kill_group(child.pid)
                if watchdog_reason is None:
                    time.sleep(min(SAMPLE_INTERVAL, max(0.0, TIME_LIMIT - (time.monotonic() - started))))
                else:
                    time.sleep(0.005)
        except BaseException:
            if child is not None and child.returncode is None:
                kill_group(child.pid)
                try:
                    _, status, usage = os.wait4(child.pid, 0)
                    child.returncode = os.waitstatus_to_exitcode(status)
                except ChildProcessError:
                    pass
            raise
    # Darwin reports bytes; Linux reports KiB. No subtraction of historical peaks.
    kernel_peak = int(usage.ru_maxrss) * (1 if sys.platform == "darwin" else 1024)
    peak = max(sampled_peak, kernel_peak)
    return {
        "startedAt": started_at,
        "finishedAt": utc_now(),
        "pid": child.pid,
        "exitCode": child.returncode,
        "terminationSignal": -child.returncode if child.returncode < 0 else None,
        "seconds": round(time.monotonic() - started, 4),
        "userSeconds": round(usage.ru_utime, 4),
        "systemSeconds": round(usage.ru_stime, 4),
        "peakRSSBytes": peak,
        "kernelPeakRSSBytes": kernel_peak,
        "sampledPeakRSSBytes": sampled_peak,
        "rssSampleCount": sample_count,
        "rssMeasurement": "wait4(exact child PID).ru_maxrss + ps RSS (KiB) every 100ms",
        "watchdogStopped": watchdog_reason is not None,
        "watchdogReason": watchdog_reason,
        "rssBudgetBytes": RSS_LIMIT,
        "timeBudgetSeconds": TIME_LIMIT,
        "withinRSSBudget": peak <= RSS_LIMIT,
    }


def sandbox_prefix(real_home):
    # Defense in depth: an unsupported CFFIXED_USER_HOME must not read the real
    # IgnoreRuleStore. Normal filesystem metadata checks and system libraries
    # remain available. The target scan root is always our generated directory.
    blocked = str(real_home / "Library/Application Support/AIYOUClean")
    profile = "(version 1) (allow default) (deny file-read* (subpath " + json.dumps(blocked) + "))"
    return ["/usr/bin/sandbox-exec", "-p", profile]


def verify_fake_home(binary, role, fixture, fake_home, environment, prefix):
    """A malformed private fixture rule must be observed before any large scan."""
    config = fake_home / "Library/Application Support/AIYOUClean/ignore-rules.json"
    config.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    config.write_text("AIYOUClean-isolation-probe-invalid-json", encoding="utf-8")
    config.chmod(0o600)
    empty_root = fixture / "isolation-probe-root"
    empty_root.mkdir(exist_ok=True)
    report_path = fixture / (role + "-isolation.json")
    result = run_child(
        prefix + [str(binary), "scan", "cleanup", "--root", str(empty_root), "--output", str(report_path)],
        environment, fixture / (role + "-isolation.log"), fixture,
    )
    report, error = read_report(report_path)
    warnings = report.get("warnings", []) if report else []
    observed = any(isinstance(warning, str) and "忽略清单损坏" in warning for warning in warnings)
    if error or result["exitCode"] != 3 or not report or report["visitedFiles"] != 0 or not observed:
        raise RuntimeError(
            "fake Home isolation was not confirmed for " + role + "; stopped before corpus generation: "
            + json.dumps({"process": result, "warnings": warnings, "reportError": error}, ensure_ascii=False)
        )
    config.write_text("[]", encoding="utf-8")
    return {"confirmed": True, "method": "CFFIXED_USER_HOME + corrupt-rule probe + sandbox denial of real config"}


def generate_tree(root, count):
    root.mkdir()
    started = time.monotonic()
    # Sparse logical data makes 120k genuine file-system entries without a
    # needless ~500 MiB payload allocation. The scan counts logical sizes.
    allocated_bytes = 0
    for directory_index, offset in enumerate(range(0, count, FILES_PER_DIRECTORY)):
        directory = root / ("group-%06d" % directory_index)
        directory.mkdir()
        for file_index in range(offset, min(offset + FILES_PER_DIRECTORY, count)):
            path = directory / ("file-%09d.bin" % file_index)
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            try:
                os.ftruncate(fd, FILE_BYTES)
                allocated_bytes += os.fstat(fd).st_blocks * 512
            finally:
                os.close(fd)
        if directory_index % 30 == 0:
            print("generated %d/%d files" % (min(offset + FILES_PER_DIRECTORY, count), count), file=sys.stderr, flush=True)
    return {
        "files": count,
        "directories": math.ceil(count / FILES_PER_DIRECTORY),
        "filesPerDirectoryMaximum": FILES_PER_DIRECTORY,
        "fileLogicalBytesEach": FILE_BYTES,
        "logicalBytes": count * FILE_BYTES,
        "fileAllocatedBytesAtCreation": allocated_bytes,
        "sparseFiles": True,
        "generationSeconds": round(time.monotonic() - started, 4),
    }


def measure(binary, role, full, args, corpus, root, fake_home, environment, prefix, output, isolation):
    name = args.label + "-" + role
    report_path = output / (name + "-scan.json")
    log_path = output / (name + "-stderr.txt")
    command = [str(binary), "scan", "cleanup", "--root", str(root)]
    if full:
        command.append("--full")
    command.extend(["--output", str(report_path)])
    before_hash = sha256(binary)
    result = run_child(prefix + command, environment, log_path, root.parent)
    report, report_error = read_report(report_path)
    after_hash = sha256(binary)
    result.update({
        "label": args.label,
        "role": role,
        "kind": "cleanup",
        "binary": str(binary),
        "binarySHA256Before": before_hash,
        "binarySHA256After": after_hash,
        "binaryUnchanged": before_hash == after_hash,
        "command": command,
        "fixture": str(root),
        "fakeHome": str(fake_home),
        "homeIsolation": isolation,
        "corpus": corpus,
        "scanReport": str(report_path),
        "stderrLog": str(log_path),
        "reportError": report_error,
        "truncated": report.get("truncated") if report else None,
        "visited": report.get("visitedFiles") if report else None,
        "items": len(report["items"]) if report else None,
        "warnings": report.get("warnings", []) if report else [],
        "scannerPeakRSSBytes": report.get("peakResidentBytes") if report else None,
        "cacheConditions": "same corpus; baseline runs first; no filesystem-cache flushing",
    })
    expected_names = {"group-%06d" % index for index in range(corpus["directories"])}
    actual_names = set()
    total_bytes = 0
    valid_paths = report is not None
    if report:
        for item in report["items"]:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str) or type(item.get("bytes")) is not int:
                valid_paths = False
                continue
            path = pathlib.Path(item["path"])
            if path.parent != root or path.name not in expected_names:
                valid_paths = False
            actual_names.add(path.name)
            total_bytes += item["bytes"]
    result["observedLogicalBytes"] = total_bytes if report else None
    result["allExpectedItemsPresent"] = (
        report is not None and valid_paths and actual_names == expected_names
        and len(report["items"]) == corpus["directories"]
    )
    result["expectedLogicalBytesPresent"] = report is not None and total_bytes == corpus["logicalBytes"]
    result["complete"] = bool(
        report and result["exitCode"] == 0 and report["truncated"] is False
        and report["visitedFiles"] >= corpus["files"]
        and result["allExpectedItemsPresent"] and result["expectedLogicalBytesPresent"]
        and not result["watchdogStopped"] and result["withinRSSBudget"] and result["binaryUnchanged"]
    )
    reasons = []
    if not result["complete"]:
        for condition, reason in [
            (report is not None, "missing-or-invalid-report"),
            (result["exitCode"] == 0, "nonzero-exit"),
            (result["truncated"] is False, "truncated-or-unknown"),
            (result["visited"] is not None and result["visited"] >= corpus["files"], "insufficient-visited-count"),
            (result["allExpectedItemsPresent"], "missing-or-invalid-items"),
            (result["expectedLogicalBytesPresent"], "logical-byte-total-mismatch"),
            (not result["watchdogStopped"], "watchdog-stop"),
            (result["withinRSSBudget"], "memory-budget-exceeded"),
            (result["binaryUnchanged"], "binary-changed-during-run"),
        ]:
            if not condition:
                reasons.append(reason)
    result["incompleteReasons"] = reasons
    write_json(output / (name + ".json"), result)
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", required=True, type=absolute_binary)
    parser.add_argument("--candidate", type=absolute_binary)
    parser.add_argument("--baseline-only", action="store_true")
    parser.add_argument("--count", type=int, default=120000)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("this benchmark requires macOS (sandbox-exec and Darwin wait4 RSS units)")
    if not hasattr(os, "wait4"):
        parser.error("Python must provide os.wait4")
    if not 1 <= args.count <= 2000000:
        parser.error("--count must be between 1 and 2000000")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.label):
        parser.error("--label must use 1-80 ASCII letters, digits, '.', '_' or '-'")
    if not args.baseline_only and args.candidate is None:
        parser.error("--candidate is required unless --baseline-only is supplied")
    def request_stop(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, request_stop)
    output = PROJECT / "analysis/performance"
    if output.is_symlink():
        parser.error("performance output directory must not be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    roles = [("baseline", args.baseline, False)]
    if not args.baseline_only:
        roles.append(("candidate", args.candidate, True))
    paths = [output / (args.label + "-comparison.json")]
    for role, _, _ in roles:
        paths.extend(output / (args.label + "-" + role + suffix) for suffix in (".json", "-scan.json", "-stderr.txt"))
    if any(path.exists() or path.is_symlink() for path in paths):
        parser.error("label already has output files; choose a fresh label to preserve evidence")
    fixture_parent = PROJECT / ".perf-fixtures"
    if fixture_parent.is_symlink():
        parser.error("fixture parent must not be a symlink")
    fixture_parent.mkdir(exist_ok=True)
    token = str(uuid.uuid4())
    fixture = fixture_parent / ("scan-scale-" + token)
    fixture.mkdir(mode=0o700)
    identity = (fixture.stat().st_dev, fixture.stat().st_ino)
    marker = fixture / ".scan-scale-owned"
    marker.write_text(token, encoding="ascii")
    results = []
    try:
        fake_home = fixture / "fake-home"
        fake_home.mkdir(mode=0o700)
        root = fixture / "cleanup-root"
        environment = os.environ.copy()
        # Override CoreFoundation's process-local home, without repurposing HOME.
        environment["CFFIXED_USER_HOME"] = str(fake_home)
        environment["TMPDIR"] = str(fixture)
        prefix = sandbox_prefix(pathlib.Path.home())
        isolation = {}
        for role, binary, _ in roles:
            isolation[role] = verify_fake_home(binary, role, fixture, fake_home, environment, prefix)
        corpus = generate_tree(root, args.count)
        for role, binary, full in roles:
            results.append(measure(binary, role, full, args, corpus, root, fake_home, environment, prefix, output, isolation[role]))
        comparison = {
            "label": args.label,
            "corpus": corpus,
            "baselineOnly": args.baseline_only,
            "baselineComplete": results[0]["complete"],
            "candidateComplete": results[1]["complete"] if len(results) > 1 else None,
            "speedComparable": len(results) > 1 and all(result["complete"] for result in results),
            "note": "A faster truncated scan is not a successful result. Compare time only when both runs are complete. A single scale cannot establish a memory-growth curve.",
            "runs": [str(output / (args.label + "-" + result["role"] + ".json")) for result in results],
        }
        write_json(output / (args.label + "-comparison.json"), comparison)
    finally:
        # Never remove a directory we did not create, or a replaced fixture root.
        if fixture.is_symlink() or not fixture.is_dir() or (fixture.stat().st_dev, fixture.stat().st_ino) != identity or marker.read_text(encoding="ascii") != token:
            raise RuntimeError("fixture ownership changed; refusing recursive cleanup: " + str(fixture))
        shutil.rmtree(fixture)
        try:
            fixture_parent.rmdir()  # Only removes the parent if now empty.
        except OSError:
            pass
        print("removed owned fixture " + str(fixture), file=sys.stderr, flush=True)
    # Baseline truncation is expected evidence, not a harness failure. A candidate
    # claiming to fix scale must complete all counts and bytes under the budgets.
    return 0 if args.baseline_only or results[-1]["complete"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("interrupted; child terminated and owned fixture cleanup attempted", file=sys.stderr)
        raise SystemExit(130)
