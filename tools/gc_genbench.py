#!/usr/bin/env python3.14
"""GG7: generational GC performance against full-only (generational GC plan §5).

Runs the collector benchmarks in three arms at CACHE_EN=1 MEM_LATENCY=4:

    full    +GC_GEN=0                    today's collector
    major   +GC_GEN=1 +GC_MAJOR_ONLY=1   generational bookkeeping, every
                                         collection a major
    gen     +GC_GEN=1                    minors and majors

and prints, per bench and arm, total cycles, GC cycles, collections
(minors/majors), p50/p95/p99/max engine cycles of one collection (mark +
sweep), remembered-set overflows and guard hits. It scores:

    PG2  gc-bench-churn: median minor at most 20% of the median full-only
         collection, and GC share at most 12%
    PG4  no bench slower in total cycles than full-only by more than 2%
    PG5  p99 and max collection at most full-only max + 5%
    PG6  no overflow and no guard hit
    PG7  reported only: majors, minors and the major rate per bench

    python3.14 tools/gc_genbench.py [--jobs N] [--arms full,gen] [--plusargs ...]
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import pathlib
import re
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
BENCHES = ["gc-bench-full", "gc-bench-churn", "gc-bench-deep", "gc-bench-wide",
           "gc-compile-loop", "gc-steady-list", "gc-steady-dict", "gc-steady-set",
           "gc-steady-str", "gc-steady-exc", "gc-steady-closure", "gc-steady-compile"]
BASE = "+GC_EN=1 +GC_ROOT_STASH=1 +MAX_CYCLES_SCALE=40 +GC_LOG=1"
ARMS = {"full": "", "major": "+GC_GEN=1 +GC_MAJOR_ONLY=1", "gen": "+GC_GEN=1"}
GEN_RE = re.compile(r"^\[GC-GEN\] n=\d+ kind=(\w+) .*?\bmark_cyc=(\d+) sweep_cyc=(\d+)", re.M)
LOG_RE = re.compile(r"^\[GC-LOG\] .*?\bmark_cyc=(\d+) sweep_cyc=(\d+)", re.M)
SUM_RE = re.compile(r"^GC-GEN minors=(\d+) majors=(\d+) guard_hits=(\d+) .*?overflows=(\d+)", re.M)


def pct(xs: list[int], q: float) -> int:
    if not xs:
        return 0
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))]


def measure(r) -> dict:
    text = r.text()
    gc = gc_gates.parse_gc_line(text) or {}
    gen = GEN_RE.findall(text)
    if gen:
        colls = [(k, int(a) + int(b)) for k, a, b in gen]
    else:
        colls = [("full", int(a) + int(b)) for a, b in LOG_RE.findall(text)]
    per = [c for _, c in colls]
    s = SUM_RE.search(text)
    return {
        "ok": r.passed,
        "cycles": r.cycles or 0,
        "gc_cycles": gc.get("total_pause", 0),
        "colls": len(colls),
        "minor": [c for k, c in colls if k == "minor"],
        "all": per,
        "minors": int(s.group(1)) if s else 0,
        "majors": int(s.group(2)) if s else len(colls),
        "guard": int(s.group(3)) if s else 0,
        "ovf": int(s.group(4)) if s else 0,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out", default=str(ROOT / "build" / "gc_genbench"))
    ap.add_argument("--arms", default="full,major,gen")
    ap.add_argument("--plusargs", default="", help="extra plusargs for the generational arms")
    ap.add_argument("--benches", default=",".join(BENCHES))
    args = ap.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    ctx = gc_gates.Context(root=ROOT, out=out, mode="full", jobs=args.jobs, head="")
    globs = args.benches.split(",")
    tests = [t for t in gc_gates.all_tests() if gc_gates.matches(t.name, globs)]
    arms = args.arms.split(",")
    res: dict[str, dict[str, dict]] = {}
    for arm in arms:
        extra = ARMS[arm] + (f" {args.plusargs}" if arm != "full" and args.plusargs else "")
        rs = gc_gates.gate_runs(ctx, "G13", f"GG7_{arm}", tests=tests, plusargs=f"{BASE} {extra}")
        res[arm] = {r.test.name: measure(r) for r in rs}
    print(f"{'bench':<20} {'arm':<6} {'cycles':>11} {'vs full':>8} {'gc_cyc':>10} {'colls':>5} "
          f"{'min/maj':>9} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'ovf':>4} {'guard':>5}")
    problems: list[str] = []
    for t in sorted(tests, key=lambda t: t.name):
        n = t.name
        base = res.get("full", {}).get(n)
        for arm in arms:
            m = res[arm].get(n)
            if not m or not m["ok"]:
                print(f"{n:<20} {arm:<6} FAIL")
                problems.append(f"{n} {arm}: run failed")
                continue
            rel = f"{m['cycles'] / base['cycles'] - 1:+.2%}" if base and base["ok"] else ""
            print(f"{n:<20} {arm:<6} {m['cycles']:>11} {rel:>8} {m['gc_cycles']:>10} {m['colls']:>5} "
                  f"{str(m['minors']) + '/' + str(m['majors']):>9} {pct(m['all'], .5):>8} "
                  f"{pct(m['all'], .95):>8} {pct(m['all'], .99):>8} {max(m['all'], default=0):>8} "
                  f"{m['ovf']:>4} {m['guard']:>5}")
        g = res.get("gen", {}).get(n)
        if not (base and g and base["ok"] and g["ok"]):
            continue
        if g["cycles"] > base["cycles"] * 1.02:
            problems.append(f"PG4 {n}: {g['cycles']} cycles, {g['cycles'] / base['cycles'] - 1:+.2%} vs full")
        fmax = max(base["all"], default=0)
        for q, v in (("p99", pct(g["all"], .99)), ("max", max(g["all"], default=0))):
            if fmax and v > fmax * 1.05:
                problems.append(f"PG5 {n}: {q} {v} > full max {fmax} + 5%")
        if g["ovf"] or g["guard"]:
            problems.append(f"PG6 {n}: {g['ovf']} overflows, {g['guard']} guard hits")
        if n == "gc-bench-churn":
            fm = statistics.median(base["all"]) if base["all"] else 0
            mm = statistics.median(g["minor"]) if g["minor"] else 0
            share = g["gc_cycles"] / max(1, g["cycles"])
            print(f"PG2 {n}: median minor {mm:.0f} = {mm / max(1, fm):.1%} of median full {fm:.0f}; "
                  f"GC share {share:.1%}")
            if not g["minor"] or mm > 0.2 * fm or share > 0.12:
                problems.append(f"PG2 {n}: minor {mm / max(1, fm):.1%} of full, share {share:.1%}")
    print()
    for p in problems:
        print(f"MISSED {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
