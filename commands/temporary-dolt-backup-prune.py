#!/usr/bin/env python3
"""Temporary native backup pruning until Beads/Gas City expose it in backup sync."""

import argparse
import csv
import fcntl
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone


CITY = Path(__file__).resolve().parent.parent
RUNTIME = CITY / ".gc/runtime/packs/dolt"
READY = CITY / ".gc/runtime/dolt-backup-prune-ready.json"
RECEIPTS = RUNTIME / "temporary-backup-prune.jsonl"


def record(**fields):
    fields["time"] = datetime.now(timezone.utc).isoformat()
    line = json.dumps(fields)
    print(line, flush=True)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with RECEIPTS.open("a") as handle:
        handle.write(line + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate configuration without SQL or pruning")
    parser.add_argument("--grace", choices=["1h", "10m"], default="1h",
                        help="native idle grace; 10m is for the initial supervised recovery only")
    args = parser.parse_args()
    config = json.loads((CITY / ".beads/dolt-backup.json").read_text())
    ready = json.loads(READY.read_text()) if READY.exists() else {}
    gc = ready.get("gc_bin") or os.environ.get("GC_BIN") or shutil.which("gc")
    if not gc or not Path(gc).is_file():
        raise RuntimeError("managed Gas City binary is unavailable during upgrade")
    gc_version = subprocess.check_output([gc, "version"], text=True).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+].*)?", gc_version):
        raise RuntimeError("resolved gc is not the expected Gas City CLI")
    backup = CITY / ".dolt-backup/hq"
    if config.get("backup_url") != backup.as_uri() or config.get("backup_name") != "default":
        raise RuntimeError("backup configuration changed; review this temporary workaround")
    version = subprocess.check_output(["dolt", "version"], text=True).strip()
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match or tuple(map(int, match.groups())) < (2, 3, 0):
        raise RuntimeError("native backup pruning requires Dolt >= 2.3.0")
    query = f"CALL DOLT_BACKUP('sync', '--prune-with-grace-period={args.grace}', 'default')"
    # bd sql uses a ten-second read timeout, which can cancel a large prune.
    # Dolt's native client discovers the existing managed server from its lock.
    source = CITY / ".beads/dolt/hq"
    command = ["dolt", "-C", str(source), "sql", "-r", "csv", "-q", query]
    if args.check:
        print(json.dumps({"city": str(CITY), "backup": str(backup), "version": version, "command": command,
                          "grace": args.grace, "lock": str(RUNTIME / "backup-sync.lock"), "ready_marker": str(READY)}))
        return 0
    if ready.get("ready") is not True:
        print(json.dumps({"outcome": "skipped", "reason": "database recovery not verified"}))
        return 0
    state = json.loads((RUNTIME / "dolt-state.json").read_text())
    if (state.get("running") is not True
            or Path(state.get("data_dir", "")).resolve() != source.parent.resolve()
            or not (source.parent / ".dolt/sql-server.info").is_file()):
        raise RuntimeError("expected managed server is not available; refusing embedded fallback")
    os.kill(int(state["pid"]), 0)
    with (RUNTIME / "backup-sync.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            record(outcome="skipped", reason="another managed backup holds the shared lock")
            return 0
        grace_seconds = 3600 if args.grace == "1h" else 600
        files = [path for path in backup.rglob("*") if path.is_file()]
        newest = max((path.stat().st_mtime for path in files), default=0)
        if time.time() - newest < grace_seconds:
            record(outcome="skipped", reason="backup destination is inside the native idle grace period",
                   eligible_after=datetime.fromtimestamp(newest + grace_seconds, timezone.utc).isoformat())
            return 0
        probe = subprocess.run([gc, "bd", "--city", str(CITY), "sql", "--csv", "SELECT DATABASE() AS db"],
                               cwd=CITY, text=True, capture_output=True, timeout=60, check=True)
        rows = list(csv.reader(io.StringIO(probe.stdout.strip())))
        if rows != [["db"], ["hq"]]:
            raise RuntimeError("managed backup source is not the expected hq database: " + probe.stdout)
        native_probe = subprocess.run(["dolt", "-C", str(source), "sql", "-r", "csv", "-q",
                                       "SELECT DATABASE() AS db"],
                                      text=True, capture_output=True, timeout=60, check=True)
        if list(csv.reader(io.StringIO(native_probe.stdout.strip()))) != [["db"], ["hq"]]:
            raise RuntimeError("native client did not reach the expected managed hq database")
        before = shutil.disk_usage(CITY).free
        backup_bytes_before = sum(path.stat().st_blocks * 512 for path in files)
        record(outcome="started", free_bytes=before, backup=str(backup), database="hq", grace=args.grace,
               backup_bytes=backup_bytes_before, backup_file_count=len(files))
        result = subprocess.run(command, cwd=CITY, timeout=1200, text=True, capture_output=True)
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", file=sys.stderr, flush=True)
        success = result.returncode == 0 and result.stdout.strip().endswith("status\n0")
        record(outcome="success" if success else "failed", returncode=result.returncode,
               free_bytes_before=before, free_bytes_after=shutil.disk_usage(CITY).free,
               backup_bytes_before=backup_bytes_before,
               backup_bytes_after=sum(path.stat().st_blocks * 512 for path in backup.rglob("*") if path.is_file()))
        return 0 if success else (result.returncode or 1)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        record(outcome="failed", error=str(error))
        sys.exit(1)
