#!/usr/bin/env python3
"""Read-only acceptance benchmark for disk-backed full CLI scan exports.

python3 scripts/disk-scan-scale.py --binary /absolute/aiyouclean-cli-0.4.0
Use --label NEW_LABEL to preserve evidence when rerunning.
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
COUNT = 12_001
PAYLOAD = b"AIYOUClean disk-backed scanner fixture\n".ljust(64, b".")
TIME_LIMIT = 180.0
RSS_LIMIT = 512 * 1024 * 1024
MAX_LINE = 2 * 1024 * 1024


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def save(path, value):
    with path.open("x", encoding="utf-8") as target:
        json.dump(value, target, ensure_ascii=False, indent=2)
        target.write("\n")


def kill(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def measure(command, environment, log, cwd):
    started = time.monotonic()
    started_at = now()
    sampled_peak = samples = 0
    stopped = None
    child = None
    with log.open("xb") as output:
        try:
            child = subprocess.Popen(command, stdout=output, stderr=output, cwd=cwd,
                                     env=environment, start_new_session=True)
            while True:
                try:
                    pid, status, usage = os.wait4(child.pid, os.WNOHANG)
                except InterruptedError:
                    continue
                if pid == child.pid:
                    child.returncode = os.waitstatus_to_exitcode(status)
                    break
                remaining = TIME_LIMIT - (time.monotonic() - started)
                if stopped is None and remaining <= 0:
                    stopped = "wall-time-180s"
                    kill(child.pid)
                if stopped is None:
                    try:
                        sample = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(child.pid)],
                                                capture_output=True, text=True, check=False,
                                                timeout=max(0.01, min(0.3, remaining)))
                        if sample.stdout.strip().isdigit():
                            samples += 1
                            sampled_peak = max(sampled_peak, int(sample.stdout.strip()) * 1024)
                            if sampled_peak > RSS_LIMIT:
                                stopped = "rss-512MiB"
                                kill(child.pid)
                    except subprocess.TimeoutExpired:
                        pass
                if stopped is None and time.monotonic() - started >= TIME_LIMIT:
                    stopped = "wall-time-180s"
                    kill(child.pid)
                time.sleep(0.005 if stopped else min(0.1, max(0, TIME_LIMIT - (time.monotonic() - started))))
        except BaseException:
            if child is not None and child.returncode is None:
                kill(child.pid)
                try:
                    _, status, usage = os.wait4(child.pid, 0)
                    child.returncode = os.waitstatus_to_exitcode(status)
                except ChildProcessError:
                    pass
            raise
    # Darwin wait4 ru_maxrss is bytes and belongs only to the requested child.
    kernel_peak = int(usage.ru_maxrss)
    return {
        "pid": child.pid, "startedAt": started_at, "finishedAt": now(),
        "seconds": round(time.monotonic() - started, 4),
        "userSeconds": round(usage.ru_utime, 4), "systemSeconds": round(usage.ru_stime, 4),
        "exitCode": child.returncode, "terminationSignal": -child.returncode if child.returncode < 0 else None,
        "peakRSSBytes": max(kernel_peak, sampled_peak), "kernelPeakRSSBytes": kernel_peak,
        "sampledPeakRSSBytes": sampled_peak, "rssSampleCount": samples,
        "rssMeasurement": "Darwin wait4(exact PID).ru_maxrss plus ps RSS every 100ms; no cumulative RUSAGE_CHILDREN",
        "watchdogStopped": stopped is not None, "watchdogReason": stopped,
        "timeBudgetSeconds": TIME_LIMIT, "rssBudgetBytes": RSS_LIMIT,
    }


def require(value, message):
    if not value:
        raise ValueError(message)


def verify_report(path, mode, sources):
    """Read every exported item, incrementally; never validate just a preview."""
    require(path.is_file(), "CLI did not produce an exported report")
    require(path.stat().st_size <= 128 * 1024 * 1024, "report exceeds the fixture's 128MiB safety bound")
    seen = bytearray(COUNT)
    count = processable = keepers = copies = 0
    byte_total = 0
    keeper_path = str(sources / "entry-00000.bin")
    keeper_stat = os.stat(keeper_path, follow_symlinks=False)
    common_retained_identity = None
    common_group = None
    expected_group = hashlib.sha256(PAYLOAD).hexdigest()
    saw_footer = False
    with path.open("rb") as handle:
        header_line = handle.readline(MAX_LINE + 1)
        require(len(header_line) <= MAX_LINE, "metadata line is too long")
        opening = header_line.rstrip(b"\r\n")
        suffix = b',"items":['
        require(opening.endswith(suffix), "expected the full streaming JSON export, not a preview or log")
        metadata = json.loads(opening[:-len(suffix)] + b"}")
        require(metadata.get("kind") == mode, "export kind mismatch")
        require(metadata.get("totalItemCount") == COUNT, "totalItemCount is not 12001")
        require(metadata.get("truncated") is False, "export is truncated or lacks an explicit completion state")
        require(metadata.get("stopReason") is None, "completed export has a stop reason")
        require(metadata.get("visitedFiles", -1) >= COUNT, "not every source file was visited")
        require(metadata.get("resultLimit") == 1, "preview option --max-results 1 was not retained")
        require(metadata.get("allItemsBytes") == COUNT * len(PAYLOAD), "full logical byte total mismatch")
        while True:
            raw = handle.readline(MAX_LINE + 1)
            if not raw:
                break
            require(len(raw) <= MAX_LINE, "item line exceeded the bounded reader size")
            line = raw.strip()
            if not line:
                continue
            if line == b"]}":
                saw_footer = True
                while True:
                    tail = handle.read(64 * 1024)
                    if not tail:
                        break
                    require(not tail.strip(), "data follows the JSON footer")
                break
            require(not saw_footer, "item follows footer")
            item = json.loads(line[:-1] if line.endswith(b",") else line)
            item_path = pathlib.Path(item.get("path", ""))
            match = re.fullmatch(r"entry-(\d{5})\.bin", item_path.name)
            require(item_path.parent == sources and match is not None, "export contains a path outside the fixture")
            index = int(match.group(1))
            require(index < COUNT and not seen[index], "missing/duplicate/unknown source row")
            seen[index] = 1
            count += 1
            require(count <= COUNT, "too many exported rows")
            require(item.get("bytes") == len(PAYLOAD), "item logical bytes differ from the source")
            identity = item.get("identity")
            require(isinstance(identity, dict), "file identity is missing")
            info = os.stat(item_path, follow_symlinks=False)
            require(identity.get("device") == info.st_dev and identity.get("inode") == info.st_ino and identity.get("size") == 64,
                    "exported source identity differs from the fixture")
            require(math.isclose(identity.get("modified", -1), info.st_mtime, rel_tol=0, abs_tol=0.000001), "source modification identity mismatch")
            byte_total += item["bytes"]
            processable += item.get("canTrash") is True
            if mode == "duplicates":
                group = item.get("group")
                require(isinstance(group, str) and group == expected_group, "duplicate group is not the actual content SHA-256")
                if common_group is None:
                    common_group = group
                require(group == common_group, "identical files were split into different groups")
                require(item.get("retainedPath") == keeper_path, "retainedPath differs from the group's deterministic keeper")
                retained = item.get("retainedIdentity")
                require(isinstance(retained, dict), "retainedIdentity missing")
                require(retained.get("device") == keeper_stat.st_dev and retained.get("inode") == keeper_stat.st_ino and retained.get("size") == 64,
                        "retainedIdentity does not identify the generated keeper")
                require(math.isclose(retained.get("modified", -1), keeper_stat.st_mtime, rel_tol=0, abs_tol=0.000001), "keeper modification identity mismatch")
                if common_retained_identity is None:
                    common_retained_identity = retained
                require(retained == common_retained_identity, "retainedIdentity differs across rows")
                if item["path"] == keeper_path:
                    keepers += 1
                    require(item.get("category") == "保留原件" and item.get("canTrash") is False, "keeper was incorrectly actionable")
                    require(identity == retained, "keeper identity differs from retainedIdentity")
                else:
                    copies += 1
                    require(item.get("category") == "重复副本" and item.get("canTrash") is True, "duplicate copy was not classified consistently")
    require(saw_footer, "export JSON is incomplete")
    require(count == COUNT and all(seen), "exported array does not contain all 12001 source files")
    require(byte_total == COUNT * 64, "exported item-byte sum mismatch")
    require(metadata.get("processableItemCount") == processable, "processableItemCount does not match exported rows")
    if mode == "duplicates":
        require(keepers == 1 and copies == COUNT - 1 and processable == COUNT - 1, "expected one keeper and 12000 copies")
    return {
        "complete": True, "truncated": metadata["truncated"], "visited": metadata["visitedFiles"],
        "totalItemCount": metadata["totalItemCount"], "exportedItemCount": count,
        "processableItemCount": processable, "exportedLogicalBytes": byte_total,
        "previewLimit": metadata["resultLimit"], "keeperCount": keepers if mode == "duplicates" else None,
        "copyCount": copies if mode == "duplicates" else None,
        "commonGroup": common_group, "retainedPath": keeper_path if mode == "duplicates" else None,
        "retainedIdentity": common_retained_identity, "allSourcePathsUnique": True,
        "reportSHA256": digest(path), "reportBytes": path.stat().st_size,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--label", default="disk-v040")
    args = parser.parse_args()
    if sys.platform != "darwin" or not hasattr(os, "wait4"):
        parser.error("requires macOS and os.wait4")
    binary = pathlib.Path(args.binary)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--binary must be an absolute executable file")
    binary = binary.resolve(strict=True)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.label):
        parser.error("--label must contain 1-80 ASCII letters, digits, '.', '_' or '-'")
    output = PROJECT / "analysis/performance"
    if output.is_symlink():
        parser.error("output directory must not be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    evidence = [output / (args.label + "-manifest.json")]
    for mode in ("downloads", "duplicates"):
        evidence.extend(output / (args.label + "-" + mode + suffix) for suffix in (".json", ".log", "-report.json"))
    if any(path.exists() or path.is_symlink() for path in evidence):
        parser.error("label already has evidence; use --label with a new name")
    parent = PROJECT / ".perf-fixtures"
    if parent.is_symlink():
        parser.error("fixture parent must not be a symlink")
    parent.mkdir(exist_ok=True)
    token = str(uuid.uuid4())
    fixture = parent / ("disk-scan-" + token)
    fixture.mkdir(mode=0o700)
    identity = (fixture.stat().st_dev, fixture.stat().st_ino)
    marker = fixture / ".disk-scan-owned"
    marker.write_text(token, encoding="ascii")
    manifest = {"label": args.label, "startedAt": now(), "binary": str(binary), "binarySHA256": digest(binary),
                "files": COUNT, "fileBytesEach": len(PAYLOAD), "sourceContentSHA256": hashlib.sha256(PAYLOAD).hexdigest(),
                "fixture": str(fixture), "modes": [], "fixtureRemoved": False, "passed": False}
    def stop(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        sources = fixture / "sources"
        fake_home = fixture / "fake-home"
        temporary = fixture / "tmp"
        for path in (sources, fake_home, temporary):
            path.mkdir(mode=0o700)
        started = time.monotonic()
        for index in range(COUNT):
            with (sources / ("entry-%05d.bin" % index)).open("xb") as handle:
                handle.write(PAYLOAD)
        manifest["generationSeconds"] = round(time.monotonic() - started, 4)
        environment = os.environ.copy()
        environment["CFFIXED_USER_HOME"] = str(fake_home)
        environment["TMPDIR"] = str(temporary)
        for mode in ("downloads", "duplicates"):
            prefix = args.label + "-" + mode
            report = output / (prefix + "-report.json")
            log = output / (prefix + ".log")
            command = [str(binary), "scan", mode, "--full", "--root", str(sources), "--home", str(fake_home),
                       "--max-results", "1", "--output", str(report)]
            print("running " + mode + " on 12001 generated files", file=sys.stderr, flush=True)
            result = measure(command, environment, log, fixture)
            result.update({"label": args.label, "mode": mode, "command": command, "report": str(report), "log": str(log),
                           "binarySHA256": manifest["binarySHA256"], "files": COUNT, "fileBytesEach": 64,
                           "homeIsolation": "explicit --home plus process-local CFFIXED_USER_HOME; sources and temp are owned UUID fixtures"})
            errors = []
            if result["exitCode"] != 0:
                errors.append("nonzero CLI exit")
            if result["watchdogStopped"]:
                errors.append("watchdog stopped the CLI")
            if result["peakRSSBytes"] > RSS_LIMIT:
                errors.append("kernel or sampled RSS exceeded 512MiB")
            if digest(binary) != manifest["binarySHA256"]:
                errors.append("binary changed during benchmark")
            try:
                result.update(verify_report(report, mode, sources))
            except (OSError, ValueError, TypeError, KeyError) as error:
                result["complete"] = False
                errors.append(str(error))
            result["validationErrors"] = errors
            result["passed"] = not errors and result.get("complete") is True
            metrics = output / (prefix + ".json")
            save(metrics, result)
            manifest["modes"].append({"mode": mode, "metrics": str(metrics), "passed": result["passed"]})
            print(json.dumps(result, ensure_ascii=False), flush=True)
        manifest["passed"] = all(run["passed"] for run in manifest["modes"]) and len(manifest["modes"]) == 2
    except BaseException as error:
        manifest["error"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        if fixture.is_symlink() or not fixture.is_dir() or (fixture.stat().st_dev, fixture.stat().st_ino) != identity or marker.read_text(encoding="ascii") != token:
            raise RuntimeError("fixture ownership changed; refusing recursive cleanup: " + str(fixture))
        shutil.rmtree(fixture)
        manifest["fixtureRemoved"] = not fixture.exists()
        manifest["finishedAt"] = now()
        save(output / (args.label + "-manifest.json"), manifest)
        try:
            parent.rmdir()
        except OSError:
            pass
        print("removed owned fixture " + str(fixture), file=sys.stderr, flush=True)
    return 0 if manifest["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("interrupted; owned CLI child and fixture cleaned up", file=sys.stderr)
        raise SystemExit(130)
