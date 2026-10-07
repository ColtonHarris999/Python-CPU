#!/usr/bin/env python3.14
"""G10 mutation testing (planning/gc_plan.md §10.2 G10).

Every mutant is compiled into the RTL and selected with `+GC_MUTANT=<n>`
(`+MUTANT=<n>` on the engine unit testbench). For each mutant this runs the
quick gate subset (§10.3) in a fixed order and records the first gate that
fails, i.e. killed the mutant. G1 runs the collector off, so it goes last:
it only matters if every collector-on gate let the mutant through. The
hardware gates run their quick sets from pycore/programs/hw_tests.toml
(`[gate.*]`: the [gc] area plus every gc-mutant-* fixture) with
`+GC_MUTANT=<n>` added.

Before any mutant, the same gates run once with no mutant: a kill only means
something if the unmutated RTL passes them.

    python3.14 tools/gc_mutants.py [--only 1,5,20] [--jobs N]
    make pycore-gc-mutants [MUTANTS=1,5,20]
    python3.14 tools/gc_mutants.py --resume   # continue an interrupted run

Writes <out>/results.tsv (default build/gc_mutants/) and prints
`G10 mutants=<n> killed=<k> survived=[...] pending=[...]`. A survivor means
the suite is too weak: add an img_gc_mutant_<n> fixture that it fails.
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
        print(f"[gc_mutants] mutant {n}: {g}", flush=True)
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
    ap.add_argument("--resume", action="store_true",
                    help="keep the results already in <out>/results.tsv from a run at the same "
                         "commit and run only the rest")
    args = ap.parse_args()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                          text=True).stdout.strip()
    todo = [int(x) for x in args.only.split(",") if x] or MUTANTS
    # Results are written as they come (row 0 is the no-mutant run), so an
    # interrupted run can --resume.
    tsv = out / "results.tsv"
    done: dict[int, tuple[str, str]] = {}
    if args.resume and tsv.exists():
        lines = tsv.read_text(encoding="utf-8").splitlines()
        if lines and lines[0] == f"# head {head}":
            for ln in lines[2:]:
                n, gate, summary = ln.split("\t", 2)
                done[int(n)] = (gate, summary)
        print(f"[gc_mutants] resuming: {len(done)} result(s) kept", flush=True)
    else:
        tsv.write_text(f"# head {head}\nmutant\tkilled_by\tsummary\n", encoding="utf-8")

    def record(n: int, gate: str, summary: str) -> None:
        with tsv.open("a", encoding="utf-8") as fh:
            fh.write(f"{n}\t{gate}\t{' '.join(summary.split())}\n")

    # A kill only means something if the unmutated RTL passes the same gates
    # (review round 4): a build break or a baseline failure would otherwise
    # "kill" every mutant.
    if 0 in done:
        gate, summary = done[0]
    else:
        gate, summary = run_mutant(0, out, args.jobs, head)
        record(0, gate, summary)
    print(f"[gc_mutants] baseline (no mutant): {'pass' if gate == 'SURVIVED' else 'FAIL at ' + gate} "
          f"{summary[:160]}", flush=True)
    if gate != "SURVIVED":
        print(f"G10 baseline failed at {gate}: {summary[:200]}")
        return 1
    rows = []
    for n in todo:
        if n in done:
            rows.append((n, *done[n]))
            continue
        if n in NEEDS_PHASE3:
            rows.append((n, "PENDING", "needs the excore grant protocol (Phase 3)"))
            print(f"[gc_mutants] mutant {n}: pending (Phase 3)", flush=True)
            continue
        t0 = time.time()
        gate, summary = run_mutant(n, out, args.jobs, head)
        rows.append((n, gate, summary))
        record(n, gate, summary)
        print(f"[gc_mutants] mutant {n}: {'killed by ' + gate if gate != 'SURVIVED' else 'SURVIVED'} "
              f"({time.time() - t0:.0f}s) {summary[:160]}", flush=True)
    for n, gate, _ in rows:
        print(f"[gc_mutants] {n:>2} {gate}")
    survived = [n for n, g, _ in rows if g == "SURVIVED"]
    pending = [n for n, g, _ in rows if g == "PENDING"]
    killed = len(rows) - len(survived) - len(pending)
    print(f"G10 mutants={len(rows)} killed={killed} survived={survived} pending={pending}")
    return 1 if survived or pending else 0


if __name__ == "__main__":
    raise SystemExit(main())
