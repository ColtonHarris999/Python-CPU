#!/usr/bin/env python3
"""G10 mutation testing (planning/gc_plan.md §10.2 G10).

Every mutant is compiled into the RTL and selected with `+GC_MUTANT=<n>`
(`+MUTANT=<n>` on the engine unit testbench). For each mutant this runs the
quick gate subset (§10.3) in a fixed order and records the first gate that
fails, i.e. killed the mutant. G1 runs the collector off, so it goes last:
it only matters if every collector-on gate let the mutant through.

    python3.14 tools/gc_mutants.py [--only 1,5,20] [--jobs N]

Writes <out>/results.tsv and prints
`G10 mutants=<n> killed=<k> survived=[...] pending=[...]`.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
MUTANTS = list(range(1, 50))
NEEDS_PHASE3: set[int] = set()
GATE_ORDER = ["G3", "G4", "G5", "G6", "G7", "G8", "G1"]


def gates_available() -> list[str]:
    return [g for g in GATE_ORDER if hasattr(gc_gates, f"gate_{g}")]


def run_mutant(n: int, out: pathlib.Path, jobs: int, head: str) -> tuple[str, str]:
    ctx = gc_gates.Context(root=ROOT, out=out / f"m{n}", mode="quick", jobs=jobs, head=head,
                           mutant=n)
    subprocess.run(["rm", "-rf", str(ctx.out)])
    ctx.out.mkdir(parents=True, exist_ok=True)
    for g in gates_available():
        res = getattr(gc_gates, f"gate_{g}")(ctx)
        (ctx.out / f"{g}.log").write_text(
            f"{res.status}: {res.summary}\n" + "\n".join(res.lines) + "\n", encoding="utf-8")
        if res.status != "pass":
            return g, res.summary
    return "SURVIVED", "every quick gate passed"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma-separated mutant numbers")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out", default=str(ROOT / "build" / "gc_mutants"))
    args = ap.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                          text=True).stdout.strip()
    todo = [int(x) for x in args.only.split(",") if x] or MUTANTS
    rows = []
    # A kill only means something if the unmutated RTL passes the same gates
    # (review round 4): a build break or a baseline failure would otherwise
    # "kill" every mutant.
    gate, summary = run_mutant(0, out, args.jobs, head)
    print(f"[gc_mutants] baseline (no mutant): {'pass' if gate == 'SURVIVED' else 'FAIL at ' + gate} "
          f"{summary[:160]}", flush=True)
    if gate != "SURVIVED":
        print(f"G10 baseline failed at {gate}: {summary[:200]}")
        return 1
    for n in todo:
        if n in NEEDS_PHASE3:
            rows.append((n, "PENDING", "needs the excore grant protocol (Phase 3)"))
            print(f"[gc_mutants] mutant {n}: pending (Phase 3)", flush=True)
            continue
        t0 = time.time()
        gate, summary = run_mutant(n, out, args.jobs, head)
        rows.append((n, gate, summary))
        print(f"[gc_mutants] mutant {n}: {'killed by ' + gate if gate != 'SURVIVED' else 'SURVIVED'} "
              f"({time.time() - t0:.0f}s) {summary[:160]}", flush=True)
    with (out / "results.tsv").open("w", encoding="utf-8") as fh:
        fh.write("mutant\tkilled_by\tsummary\n")
        for n, gate, summary in rows:
            fh.write(f"{n}\t{gate}\t{summary}\n")
    survived = [n for n, g, _ in rows if g == "SURVIVED"]
    pending = [n for n, g, _ in rows if g == "PENDING"]
    killed = len(rows) - len(survived) - len(pending)
    print(f"G10 mutants={len(rows)} killed={killed} survived={survived} pending={pending}")
    return 1 if survived or pending else 0


if __name__ == "__main__":
    raise SystemExit(main())
