#!/usr/bin/env python3.14
"""G13 benchmark table (planning/gc_plan.md §10.2; pycore/docs/gc.md, Performance).

Runs the G13 set of pycore/programs/hw_tests.toml (`[gate.G13]`: the
gc-bench-* tests and gc-compile-loop) at CACHE_EN=1 MEM_LATENCY=4 with the
collector on and `+GC_LOG=1`, prints each test's counter line and scores
P3-P7. With `--fuzz-out DIR` (a gc_fuzz.py --out directory) it also scores
P8 over that corpus.

    python3.14 tools/gc_bench.py [--jobs N] [--fuzz-out build/gc_fuzz]
    make pycore-gc-bench
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out", default=str(ROOT / "build" / "gc_bench"))
    ap.add_argument("--fuzz-out", help="gc_fuzz.py output directory to score P8 over")
    args = ap.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    ctx = gc_gates.Context(root=ROOT, out=out, mode="full", jobs=args.jobs, head="")
    res = gc_gates.gate_runs(ctx, "G13")
    print(f"{'test':<18} {'cycles':>10} {'colls':>5} {'live':>8} {'max_pause':>9} "
          f"{'total_pause':>11} {'mark_cyc':>9} {'sweep_cyc':>9} {'port_util':>9} "
          f"{'spills':>6} {'mark_xacts':>10} {'share':>6}")
    for r in sorted(res, key=lambda r: r.test.name):
        gc = gc_gates.parse_gc_line(r.text())
        if not r.passed or not gc:
            print(f"{r.test.name:<18} FAIL {r.detail}")
            continue
        cyc = r.cycles or 1
        print(f"{r.test.name:<18} {cyc:>10} {gc['collections']:>5} {gc['live']:>8} "
              f"{gc['max_pause']:>9} {gc['total_pause']:>11} {gc['mark_cyc']:>9} "
              f"{gc['sweep_cyc']:>9} {gc['port_busy_mark'] / max(1, gc['mark_cyc']):>9.3f} "
              f"{gc['stack_spills']:>6} {gc['mark_xacts']:>10} {gc['total_pause'] / cyc:>6.3f}")
    _, lines, problems = gc_gates.perf_metrics(res)
    print()
    for ln in lines:
        if ln.startswith("P"):
            print(ln)
    if args.fuzz_out:
        fuzz = pathlib.Path(args.fuzz_out).resolve()
        pops, allocs = gc_gates.p8_rate(fuzz)
        rate = pops / allocs if allocs else float("nan")
        print(f"P8 run pops/alloc {rate:.4f} ({pops}/{allocs}) over {fuzz}")
        if not allocs or rate > 0.05:
            problems.append(f"P8 run-list pops per allocation {rate:.4f} > 0.05 or no corpus")
    for p in problems:
        print(f"MISSED {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
