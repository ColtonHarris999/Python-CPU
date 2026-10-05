#!/usr/bin/env python3
"""Capture the G0 baseline (planning/gc_plan.md §10.2 G0).

Runs everything `make all-tests` runs, on an unmodified checkout, and writes:

- `pycore/tests/data/gc_baseline_cycles.tsv`: one row per simulator run with
  `target, top, cache_en, mem_latency, kind, tag_or_trap_code, value, cycles`
  (failing runs are written with `kind=fail` so G1 can exclude exactly the
  pre-existing failures);
- `pycore/tests/data/gc_baseline_verilator_warnings.txt`: the normalised
  Verilator warning list of both shared simulator builds;
- `pycore/tests/data/gc_baseline_aux.tsv`: pass/fail of the non-image
  `all-tests` steps.

The image suites run leaf by leaf through `tools/gc_suite.py` so that every
`PASS:` line is attributed to its target, top, CACHE_EN and MEM_LATENCY.
`all-tests` runs `pycore-img` at (CACHE_EN, MEM_LATENCY) = (1,4) twice
(default and the transparency arm) and (0,4) twice (transparency and the
latency sweep); the runs are deterministic, so each configuration is run once.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gc_suite  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "pycore" / "tests" / "data"

# (name, suites, CACHE_EN, MEM_LATENCY): the unique configurations of all-tests.
ALL_TESTS_CONFIGS = [
    ("default", ["pycore-container", "pycore-img", "pycore-excore-system", "pycore-img-two-core"], 1, 4),
    ("ce0_lat4", ["pycore-img"], 0, 4),
    ("ce0_lat1", ["pycore-img"], 0, 1),
    ("ce0_lat30", ["pycore-img"], 0, 30),
    ("ce1_lat30", ["pycore-img-recursion"], 1, 30),
]
AUX_STEPS = [
    "pycore-python-tests",
    "pycore-size-report",
    "pycore-rtl-unit",
    "excore-asm-tests",
    "excore-cpu-test",
]
TSV_HEADER = ["target", "top", "cache_en", "mem_latency", "kind", "tag_or_trap_code", "value", "cycles"]
WARN_RE = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:]+):\d+:\d+: (.*)$")


def normalise_warnings(text: str) -> list[str]:
    """`CODE file message` per warning, line numbers dropped (they drift)."""
    out = set()
    for line in text.splitlines():
        m = WARN_RE.match(line.strip())
        if m:
            out.add(f"{m.group(1)}\t{m.group(2)}\t{m.group(3).strip()}")
    return sorted(out)


def build_sims(repo: Path, log: Path) -> str:
    for d in ("sim_img", "sim_img_twocore"):
        subprocess.run(["rm", "-rf", str(repo / "build" / d)])
    res = subprocess.run(["make", "pycore-sim-img", "pycore-sim-img-twocore", "excore-fw"],
                         cwd=repo, capture_output=True, text=True)
    text = res.stdout + res.stderr
    log.write_text(text, encoding="utf-8")
    if res.returncode != 0:
        raise SystemExit(f"simulator build failed; see {log}")
    return text


def rows_for(results: list[gc_suite.SimRun]) -> list[list[str]]:
    rows = []
    for r in results:
        kind = r.kind if r.status == "pass" else "fail"
        rows.append([r.target, r.top, str(r.cache_en), str(r.mem_latency), kind,
                     str(r.tag_or_trap_code), r.value, str(r.cycles)])
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(ROOT), help="checkout to measure (unmodified design target)")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out-dir", default=str(DATA))
    ap.add_argument("--log-dir", default="build/gc_baseline")
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    out_dir = Path(args.out_dir).resolve()
    log_dir = Path(args.log_dir).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
    t0 = time.time()

    build_text = build_sims(repo, log_dir / "sim_build.log")
    warnings = normalise_warnings(build_text)
    (out_dir / "gc_baseline_verilator_warnings.txt").write_text(
        f"# Verilator warnings of both shared simulator builds at {head}\n"
        "# code<TAB>file<TAB>message (line numbers dropped)\n" + "\n".join(warnings) + "\n",
        encoding="utf-8")

    aux_rows = []
    for step in AUX_STEPS:
        res = subprocess.run(["make", step], cwd=repo, capture_output=True, text=True)
        (log_dir / f"aux_{step}.log").write_text(res.stdout + res.stderr, encoding="utf-8")
        aux_rows.append([step, "pass" if res.returncode == 0 else "fail"])
        print(f"[gc_baseline] {step}: {aux_rows[-1][1]}", flush=True)
    (out_dir / "gc_baseline_aux.tsv").write_text(
        "step\tstatus\n" + "".join("\t".join(r) + "\n" for r in aux_rows), encoding="utf-8")

    rules = gc_suite.parse_makefile(repo / "Makefile")
    all_rows: list[list[str]] = []
    for name, suites, ce, lat in ALL_TESTS_CONFIGS:
        leaves = gc_suite.expand(rules, suites)
        results = gc_suite.run_leaves(repo, leaves, ce, lat, log_dir / name, args.jobs, rules=rules)
        all_rows.extend(rows_for(results))
        bad = [r for r in results if r.status != "pass"]
        print(f"[gc_baseline] {name}: {len(results) - len(bad)} pass, {len(bad)} fail", flush=True)
        for r in bad:
            print(f"  FAIL {r.target}: {r.detail}", flush=True)

    with (out_dir / "gc_baseline_cycles.tsv").open("w", encoding="utf-8") as fh:
        fh.write(f"# G0 baseline at {head}; tools/gc_baseline.py\n")
        fh.write("\t".join(TSV_HEADER) + "\n")
        for row in all_rows:
            fh.write("\t".join(row) + "\n")
    print(f"[gc_baseline] wrote {len(all_rows)} rows in {time.time() - t0:.0f}s", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
