#!/usr/bin/env python3.14
"""GC acceptance runner (planning/gc_plan.md §10.3).

`make pycore-gc-acceptance MODE=quick|full` runs gates G0..G16 in order and
writes `build/gc_acceptance/status.json`, one log per gate
(`build/gc_acceptance/G<n>.log`) and `build/gc_acceptance/report.md`.
MODE=quick runs G0-G8; MODE=full runs every gate.

The gates that run hardware tests take their test sets and plusargs from the
`[gate.*]` tables of pycore/programs/hw_tests.toml and run them through
pycore/tools/hw_tests.py; each run logs to
`build/gc_acceptance/runs/<gate>/<test>/` (tools/gc_gates.py).

Rules (§10.3):
- fails closed: a missing target, file, unparsable output, or crash is `fail`;
- `full` has no skip flags; `--only G4,G5` writes `"mode": "partial"`;
- records `head` and `dirty` at the start; if HEAD moves the run is invalid;
- `--record-review <file>` appends G15 evidence to `planning/gc_reviews.md`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "gc_acceptance"
GATES = [f"G{i}" for i in range(17)]
# §10.3 MODE=quick inner loop. MODE=full runs every gate.
QUICK_GATES = ["G0", "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8"]
SOURCE_SUFFIXES = {".sv", ".svh", ".py", ".s", ".md", ".json", ".yml"}
REVIEWS = ROOT / "planning" / "gc_reviews.md"


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True,
                          capture_output=True, text=True).stdout


def tree_dirty() -> list[str]:
    dirty = []
    for line in git("status", "--porcelain", "--untracked-files=all").splitlines():
        code, path = line[:2], line[3:]
        if code != "??":
            dirty.append(path)
            continue
        p = pathlib.PurePosixPath(path)
        if p.name == "Makefile" or p.suffix in SOURCE_SUFFIXES:
            dirty.append(path)
    return dirty


def record_review(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8")
    head = git("rev-parse", "HEAD").strip()
    stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    if not REVIEWS.exists():
        REVIEWS.write_text("# GC independent reviews (G15)\n\n", encoding="utf-8")
    with REVIEWS.open("a", encoding="utf-8") as fh:
        fh.write(f"## Review round at {head} ({stamp})\n\n{text.rstrip()}\n\n")
    print(f"appended review of {head} to {REVIEWS.relative_to(ROOT)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["quick", "full"], default="quick")
    ap.add_argument("--only", default="", help="comma-separated gate ids (writes mode=partial)")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--record-review", default="")
    args = ap.parse_args()
    if args.record_review:
        return record_review(pathlib.Path(args.record_review))

    OUT.mkdir(parents=True, exist_ok=True)
    # G5/G6 scan every log under runs/; leftover G7_b INV logs from a killed
    # MODE=full made MODE=quick G6 fail (f326e22 for-iter wild_ptr).
    for sub in ("runs", "G8"):
        p = OUT / sub
        if p.is_dir():
            subprocess.run(["rm", "-rf", str(p)], check=True)
    head = git("rev-parse", "HEAD").strip()
    dirty_paths = tree_dirty()
    only = [g.strip() for g in args.only.split(",") if g.strip()]
    mode = "partial" if only else args.mode
    if not only and args.mode == "quick":
        only = list(QUICK_GATES)
    started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    ctx = gc_gates.Context(root=ROOT, out=OUT, mode=args.mode, jobs=args.jobs, head=head)
    status: dict = {
        "schema": 1,
        "mode": mode,
        "head": head,
        "dirty": bool(dirty_paths),
        "dirty_paths": dirty_paths[:40],
        "started": started,
        "finished": None,
        "gates": {},
    }
    status_path = OUT / "status.json"

    def flush() -> None:
        status_path.write_text(json.dumps(status, indent=1), encoding="utf-8")

    flush()
    selected = only or GATES
    for gate in GATES:
        if gate not in selected:
            continue
        log_path = OUT / f"{gate}.log"
        t0 = time.time()
        fn = getattr(gc_gates, f"gate_{gate}", None)
        try:
            if fn is None:
                result = gc_gates.Result("fail", f"{gate} is not implemented", ["no gate function"])
            else:
                result = fn(ctx)
        except Exception:  # noqa: BLE001 - fail closed on any crash
            result = gc_gates.Result("fail", f"{gate} crashed", [traceback.format_exc()])
        elapsed = time.time() - t0
        log_path.write_text(
            f"{gate} status={result.status} elapsed={elapsed:.0f}s\n{result.summary}\n\n"
            + "\n".join(result.lines) + "\n",
            encoding="utf-8",
        )
        status["gates"][gate] = {
            "status": result.status,
            "log": str(log_path.relative_to(ROOT)),
            "summary": result.summary[:400],
            "elapsed_s": round(elapsed),
        }
        print(f"[gc_acceptance] {gate}: {result.status} ({elapsed:.0f}s) {result.summary[:200]}", flush=True)
        flush()
        if git("rev-parse", "HEAD").strip() != head:
            status["invalid"] = "HEAD moved during the run"
            status["mode"] = "invalid"
            flush()
            print("[gc_acceptance] HEAD moved during the run; the run is invalid", flush=True)
            return 2
    status["finished"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    flush()
    lines = ["# GC acceptance report\n", f"- mode: {mode}", f"- head: {head}",
             f"- dirty: {status['dirty']}", f"- started: {started}",
             f"- finished: {status['finished']}\n", "| Gate | Status | Summary |", "| --- | --- | --- |"]
    for gate in GATES:
        g = status["gates"].get(gate)
        if g:
            lines.append(f"| {gate} | {g['status']} | {g['summary'].replace('|', '/')} |")
    (OUT / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    passed = sum(1 for g in status["gates"].values() if g["status"] == "pass")
    print(f"[gc_acceptance] {passed}/{len(status['gates'])} gates pass; mode={mode} dirty={status['dirty']}")
    return 0 if passed == len(selected) else 1


if __name__ == "__main__":
    raise SystemExit(main())
