#!/usr/bin/env python3.14
"""Fast GC test tiers (generational GC plan §10): `make gc-dev`, `make gc-check`.

Both run the same gate code as `make pycore-gc-acceptance MODE=quick`
(tools/gc_gates.py) on smaller or cached inputs, so a pass here predicts a
pass there:

  dev    (~3 min)   rebuild the simulators; G2 only if gc_model.py changed
                    since the merge base; G3 at 50 seeds x 2 memory configs
                    plus the directed cases; G4-G6 on [gc] + [gc-gen] with
                    dumps checked against the oracle; G8 on 6 seeds with
                    cached peaks (seeds that still cover every kind and
                    site row). Stops at the first failing step.
  check  (<10 min)  rebuild; G1 against the merge base (measured once per
                    merge base and cached); G2-G7 as in MODE=quick; G8 on
                    16 seeds with cached peaks (10 fixed seeds that cover
                    every allocation-site row and pointer kind, 6 that rotate
                    with the commit); the performance ledger (tools/gc_perf.py).

What makes them fast, without changing what a gate checks: the G8 peak cache
(gc_fuzz.py --peaks), fewer G8 seeds, image builds cached by content
(hw_tests.image_key), G1 against a cached merge-base baseline, a process
pool for the G3 oracle, and parallel Verilator builds.

    python3.14 tools/gc_check.py --tier check [--jobs N] [--keep-going]

Writes build/gc_check/<tier>/status.json and one log per step.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_baseline  # noqa: E402
import gc_gates  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
PEAKS = ROOT / "pycore" / "tests" / "data" / "gc_fuzz_peaks.tsv"
# G8 seeds, chosen from a cached-peak run of the 50-seed quick corpus on
# b14600b. DEV_SEEDS is the cheapest set that covers every pointer kind and
# allocation-site row (11, 12, 24, 40, 46) plus seed 0; CHECK_FIXED adds the
# next cheapest. Both tiers require complete coverage, so a generator or RTL
# change that loses a kind or row fails here and the set is re-chosen.
# Rotating seeds come from the rest, except the 14 seeds whose shrunk run
# takes over a minute (those run in MODE=quick and nightly).
DEV_SEEDS = [0, 11, 12, 24, 40, 46]
CHECK_FIXED = [0, 6, 11, 12, 14, 18, 24, 30, 40, 46]
SLOW_SEEDS = {1, 3, 7, 15, 23, 25, 27, 29, 31, 33, 39, 43, 45, 49}
ROTATING = 6
QUICK_SEEDS = 50
SIMS = ["pycore-sim-img", "pycore-sim-img-twocore", "build/tb_gc/Vtb_gc", "excore-fw"]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def rotating_seeds(head: str, n: int = ROTATING) -> list[int]:
    """n seeds of 0..QUICK_SEEDS-1 outside CHECK_FIXED, chosen by the commit
    hash, so successive commits sample the rest of the quick corpus."""
    pool = [s for s in range(QUICK_SEEDS) if s not in CHECK_FIXED and s not in SLOW_SEEDS]
    return sorted(random.Random(int(head[:8] or "0", 16)).sample(pool, min(n, len(pool))))


def step_build(ctx: gc_gates.Context) -> gc_gates.Result:
    rc, out = gc_gates.run(["make", "-j3", *SIMS, f"TEST_JOBS={ctx.jobs}"])
    (ctx.out / "build.log").write_text(out, encoding="utf-8")
    if rc != 0:
        return gc_gates.Result("fail", "simulator build failed", out.splitlines()[-30:])
    return gc_gates.Result("pass", "simulators up to date")


def step_unit_dev(ctx: gc_gates.Context) -> gc_gates.Result:
    rc, out = gc_gates.run([sys.executable, str(ROOT / "tools" / "gc_unit.py"), "--seeds", "50",
                            "--configs", "dev", "--jobs", str(ctx.jobs), "--mutant", str(ctx.mutant)])
    (ctx.out / "G3_run.log").write_text(out, encoding="utf-8")
    m = re.search(r"^G3 .*$", out, re.M)
    lines = out.splitlines()[-20:]
    if rc != 0 or not m:
        return gc_gates.Result("fail", m.group(0) if m else "gc_unit.py produced no summary", lines)
    return gc_gates.Result("pass", m.group(0), lines)


def step_g2_if_changed(ctx: gc_gates.Context) -> gc_gates.Result:
    base = gc_baseline.merge_base()
    changed = git("diff", "--name-only", base, "--", "pycore/tools/gc_model.py",
                  "pycore/tests/test_gc_model.py")
    dirty = git("status", "--porcelain", "--", "pycore/tools/gc_model.py", "pycore/tests/test_gc_model.py")
    if not changed and not dirty:
        return gc_gates.Result("pass", "skipped: the oracle is unchanged since the merge base")
    return gc_gates.gate_G2(ctx)


def step_perf(ctx: gc_gates.Context) -> gc_gates.Result:
    rc, out = gc_gates.run([sys.executable, str(ROOT / "tools" / "gc_perf.py"), "--jobs", str(ctx.jobs)])
    (ctx.out / "perf.log").write_text(out, encoding="utf-8")
    m = re.search(r"^GCPERF .*$", out, re.M)
    lines = [ln for ln in out.splitlines() if ln.startswith("[gc_perf]")]
    if rc != 0 or not m:
        return gc_gates.Result("fail", m.group(0) if m else "gc_perf.py produced no summary", lines)
    return gc_gates.Result("pass", m.group(0), lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", choices=["dev", "check"], default="check")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--keep-going", action="store_true", help="run every step after a failure (dev)")
    ap.add_argument("--no-build", action="store_true", help="use the simulators as they are")
    ap.add_argument("--mutant", type=int, default=0, help="run the tier against collector mutant N")
    args = ap.parse_args()

    out = ROOT / "build" / "gc_check" / args.tier
    for sub in ("runs", "G8"):
        shutil.rmtree(out / sub, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    head = git("rev-parse", "HEAD")
    ctx = gc_gates.Context(root=ROOT, out=out, mode="quick", jobs=args.jobs, head=head,
                           g8_peaks=str(PEAKS), mutant=args.mutant)
    if args.tier == "dev":
        ctx.g8_seeds = ",".join(map(str, DEV_SEEDS))
        steps = [("G2", step_g2_if_changed), ("G3", step_unit_dev), ("G4", gc_gates.gate_G4),
                 ("G5", gc_gates.gate_G5), ("G6", gc_gates.gate_G6), ("G8", gc_gates.gate_G8)]
        fail_fast = not args.keep_going
    else:
        ctx.g8_seeds = ",".join(map(str, sorted(CHECK_FIXED + rotating_seeds(head))))
        steps = [("G1", gc_gates.gate_G1), ("G2", gc_gates.gate_G2), ("G3", gc_gates.gate_G3),
                 ("G4", gc_gates.gate_G4), ("G5", gc_gates.gate_G5), ("G6", gc_gates.gate_G6),
                 ("G7", gc_gates.gate_G7), ("G8", gc_gates.gate_G8), ("perf", step_perf)]
        fail_fast = False
    if not args.no_build:
        steps.insert(0, ("build", step_build))

    t_start = time.time()
    status = {"tier": args.tier, "head": head, "g8_seeds": ctx.g8_seeds, "steps": {}}
    ok = True
    for name, fn in steps:
        t0 = time.time()
        try:
            res = fn(ctx)
        except Exception as exc:  # noqa: BLE001 - fail closed, like gc_acceptance
            res = gc_gates.Result("fail", f"{name} crashed: {exc!r}")
        dt = time.time() - t0
        (out / f"{name}.log").write_text(f"{name} status={res.status} elapsed={dt:.0f}s\n{res.summary}\n\n"
                                         + "\n".join(res.lines) + "\n", encoding="utf-8")
        status["steps"][name] = {"status": res.status, "elapsed_s": round(dt), "summary": res.summary[:400]}
        (out / "status.json").write_text(json.dumps(status, indent=1), encoding="utf-8")
        print(f"[gc_check:{args.tier}] {name}: {res.status} ({dt:.0f}s) {res.summary[:200]}", flush=True)
        if res.status != "pass":
            ok = False
            if fail_fast:
                break
    total = time.time() - t_start
    status["elapsed_s"] = round(total)
    (out / "status.json").write_text(json.dumps(status, indent=1), encoding="utf-8")
    passed = sum(1 for s in status["steps"].values() if s["status"] == "pass")
    print(f"[gc_check:{args.tier}] {passed}/{len(steps)} steps pass in {total:.0f}s "
          f"({total / 60:.1f} min)", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
