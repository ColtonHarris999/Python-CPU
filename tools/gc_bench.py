#!/usr/bin/env python3
"""G13 benchmark table (planning/gc_plan.md §10.2).

Runs the img_gc_bench_* fixtures at CACHE_EN=1 MEM_LATENCY=4 and prints the
counter-line metrics. The acceptance gate scores those numbers as P3-P8.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
CYC_RE = re.compile(r"cycles=(\d+)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out", default=str(ROOT / "build" / "gc_bench"))
    args = ap.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    ctx = gc_gates.Context(root=ROOT, out=out, mode="full", jobs=args.jobs, head="")
    targets = list(gc_gates.BENCH.values())
    res, _ = gc_gates.gc_runs(ctx, "bench", targets, 1, 4, "+GC_LOG=1", dump=False)
    print(f"{'fixture':<28} collections live     free  max_pause total_pause "
          f"mark_cyc sweep_cyc port_util")
    rc = 0
    for x in res:
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        gc = gc_gates.parse_gc_line(text)
        cyc = CYC_RE.search(text)
        if x.status != "pass" or not gc:
            print(f"{x.target:<28} FAIL {x.detail}")
            rc = 1
            continue
        util = gc["port_busy_mark"] / max(1, gc["mark_cyc"])
        print(f"{x.target:<28} {gc['collections']:11d} {gc['live']:8d} {gc['free']:8d} "
              f"{gc['max_pause']:9d} {gc['total_pause']:11d} {gc['mark_cyc']:8d} "
              f"{gc['sweep_cyc']:9d} {util:8.3f}")
        if cyc:
            share = gc["total_pause"] / max(1, int(cyc.group(1)))
            print(f"  cycles={cyc.group(1)} GC_share={share:.3f} "
                  f"spills={gc['stack_spills']} mark_xacts={gc['mark_xacts']} "
                  f"run_pops={gc['run_pops']}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
