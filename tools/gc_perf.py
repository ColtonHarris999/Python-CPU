#!/usr/bin/env python3.14
"""GC performance ledger (generational GC plan §9.2).

Runs a fixed set of collector benchmarks at the default memory config
(CACHE_EN=1, MEM_LATENCY=4) and compares each with its row in
pycore/tests/data/gc_perf.tsv. The columns are the terms of the plan's cost
model, so a change shows which term it moved:

    cycles        total simulated cycles
    gc_cycles     total_pause: every cycle the core spent in a collection
    mark, sweep   engine mark and sweep cycles (all collections)
    mark_xacts    marker and tracer memory transactions
    zero_lines    64 B lines zeroed when runs are installed
    collections   number of collections
    max_pause     longest single pause
    p50, p95      engine cycles (mark + sweep) of one collection, from
                  the [GC-LOG] lines
    run_pops      runs the allocator popped from the run list

    python3.14 tools/gc_perf.py             # compare; fails on a regression
    python3.14 tools/gc_perf.py --update    # rewrite the ledger rows

A run fails when `cycles` or `gc_cycles` of any bench is more than 2% above
its ledger row (the simulator is deterministic, so any change is real). A PR
that makes the collector cheaper or dearer on purpose updates the ledger and
says why; that is how gains are recorded where the next change sees them.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import statistics
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))
import hw_tests  # noqa: E402

LEDGER = ROOT / "pycore" / "tests" / "data" / "gc_perf.tsv"
OUT = ROOT / "build" / "gc_perf"
BENCHES = ["gc-bench-churn", "gc-steady-dict", "gc-bench-full", "gc-bench-deep",
           "gc-bench-wide", "gc-steady-compile"]
COLUMNS = ["cycles", "gc_cycles", "mark", "sweep", "mark_xacts", "zero_lines", "collections",
           "max_pause", "p50", "p95", "run_pops"]
GATED = ("cycles", "gc_cycles")
TOLERANCE = 0.02
LOG_RE = re.compile(r"^\[GC-LOG\] .*?\bmark_cyc=(\d+) sweep_cyc=(\d+)", re.M)


def measure(r: hw_tests.Result) -> dict[str, int]:
    text = r.text()
    gc = hw_tests.parse_gc_line(text)
    per = sorted(int(a) + int(b) for a, b in LOG_RE.findall(text))
    return {
        "cycles": r.cycles or 0,
        "gc_cycles": gc.get("total_pause", 0),
        "mark": gc.get("mark_cyc", 0),
        "sweep": gc.get("sweep_cyc", 0),
        "mark_xacts": gc.get("mark_xacts", 0),
        "zero_lines": gc.get("zero_lines", 0),
        "collections": gc.get("collections", 0),
        "max_pause": gc.get("max_pause", 0),
        "p50": int(statistics.median(per)) if per else 0,
        "p95": per[min(len(per) - 1, (len(per) * 95) // 100)] if per else 0,
        "run_pops": gc.get("run_pops", 0),
    }


def load_ledger() -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    if not LEDGER.exists():
        return out
    lines = [ln for ln in LEDGER.read_text(encoding="utf-8").splitlines() if not ln.startswith("#")]
    head = lines[0].split("\t")
    for ln in lines[1:]:
        vals = ln.split("\t")
        out[vals[0]] = {k: int(v) for k, v in zip(head[1:], vals[1:])}
    return out


def write_ledger(rows: dict[str, dict[str, int]], head: str) -> None:
    with LEDGER.open("w", encoding="utf-8") as fh:
        fh.write(f"# GC performance ledger (tools/gc_perf.py --update) at {head}; "
                 "CACHE_EN=1 MEM_LATENCY=4\n")
        fh.write("bench\t" + "\t".join(COLUMNS) + "\n")
        for name in BENCHES:
            if name in rows:
                fh.write(name + "\t" + "\t".join(str(rows[name][c]) for c in COLUMNS) + "\n")


def compare(got: dict[str, dict[str, int]], ledger: dict[str, dict[str, int]]) -> tuple[list[str], list[str]]:
    """(regressions, lines): a regression is a gated column more than
    TOLERANCE above its ledger value, or a bench with no ledger row."""
    bad: list[str] = []
    lines: list[str] = []
    for name in BENCHES:
        g = got.get(name)
        if g is None:
            bad.append(f"{name}: did not run")
            continue
        old = ledger.get(name)
        if old is None:
            bad.append(f"{name}: no ledger row (run --update)")
            continue
        cells = []
        for c in COLUMNS:
            o, n = old.get(c, 0), g[c]
            delta = (n - o) / o if o else (0.0 if n == 0 else 1.0)
            cells.append(f"{c}={n}" + (f"({delta:+.1%})" if n != o else ""))
            if c in GATED and delta > TOLERANCE:
                bad.append(f"{name}: {c} {o} -> {n} ({delta:+.1%}, limit +{TOLERANCE:.0%})")
        lines.append(f"{name}: " + " ".join(cells))
    return bad, lines


def run(jobs: int, mutant: int = 0) -> dict[str, dict[str, int]]:
    tests = [t for t in hw_tests.load_manifest() if t.name in BENCHES]
    plus = "+GC_LOG=1" + (f" +GC_MUTANT={mutant}" if mutant else "")
    res = hw_tests.run_tests(tests, [hw_tests.config("1,4")], jobs=jobs, plusargs=plus, out=OUT,
                             echo=None)
    got = {}
    for r in res:
        if not r.passed:
            print(f"[gc_perf] FAIL {r.test.name}: {r.detail}", flush=True)
            continue
        got[r.test.name] = measure(r)
    return got


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--update", action="store_true", help="rewrite the ledger with this run")
    args = ap.parse_args()
    t0 = time.time()
    got = run(args.jobs)
    ledger = load_ledger()
    bad, lines = compare(got, ledger)
    for ln in lines:
        print(f"[gc_perf] {ln}")
    if args.update:
        import subprocess  # noqa: PLC0415
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,
                              text=True).stdout.strip()
        write_ledger({**ledger, **got}, head)
        print(f"[gc_perf] ledger rewritten ({len(got)} benches) in {time.time() - t0:.0f}s")
        return 0 if len(got) == len(BENCHES) else 1
    for b in bad:
        print(f"[gc_perf] REGRESSION {b}")
    print(f"GCPERF benches={len(got)}/{len(BENCHES)} regressions={len(bad)} in {time.time() - t0:.0f}s")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
