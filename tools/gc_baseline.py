#!/usr/bin/env python3
"""Capture the G0 baseline (planning/gc_plan.md §10.2 G0).

Runs what `make test-hw` and `make test-caching` run outside the GC areas,
with the collector off (`+GC_EN=0`), and writes:

- `pycore/tests/data/gc_baseline_cycles.tsv`: one row per simulator run with
  `target, top, cache_en, mem_latency, kind, tag_or_trap_code, value, cycles`
  (`target` is the `hw_tests.toml` test name; failing runs are written with
  `kind=fail` so G1 can exclude exactly the pre-existing failures);
- `pycore/tests/data/gc_baseline_verilator_warnings.txt`: the normalised
  Verilator warning list of both shared simulator builds;
- `pycore/tests/data/gc_baseline_aux.tsv`: pass/fail of the non-simulator
  `test-all` steps.

Every run goes through `tools/gc_suite.py`, so each `PASS:` line is
attributed to its test, top, CACHE_EN and MEM_LATENCY.

    python3.14 tools/gc_baseline.py [--jobs N]
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
import hw_tests  # noqa: E402  (gc_suite puts pycore/tools on the path)

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "pycore" / "tests" / "data"

# (name, suites, CACHE_EN, MEM_LATENCY, scope): the configurations of
# test-hw (default) and test-caching. scope "sample" keeps only the
# caching = true entries of hw_tests.SAMPLED_AREAS, as the caching gate does.
ALL_TESTS_CONFIGS = [
    ("default", ["hw"], 1, 4, "all"),
] + [
    (f"ce{ce}_lat{lat}", ["hw"], ce, lat, scope)
    for _, ce, lat, scope in hw_tests.CACHING_CONFIGS
]
# The collector stays off however the RTL or hw_tests default changes.
BASELINE_PLUSARGS = "+GC_EN=0"
AUX_STEPS = [
    "pycore-python-tests",
    "pycore-size-report",
    "excore-asm-tests",
    "pycore-allocator-host",
    "pycore-rtl-unit",
    "excore-cpu-test",
]
TSV_HEADER = ["target", "top", "cache_en", "mem_latency", "kind", "tag_or_trap_code", "value", "cycles"]
WARN_RE = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:]+):\d+:\d+: (.*)$")


def config_tests(suites: list[str], scope: str, tests: dict[str, hw_tests.Test]) -> list[str]:
    """Test names one baseline configuration runs."""
    names = gc_suite.expand(suites, tests)
    if scope == "sample":
        names = [n for n in names
                 if tests[n].area not in hw_tests.SAMPLED_AREAS or tests[n].caching]
    return names


def required_pairs(tests: dict[str, hw_tests.Test]) -> list[tuple[str, str, str]]:
    """(test, CACHE_EN, MEM_LATENCY) for every run the baseline must hold."""
    out = []
    for _, suites, ce, lat, scope in ALL_TESTS_CONFIGS:
        out += [(n, str(ce), str(lat)) for n in config_tests(suites, scope, tests)]
    return out


def normalise_warnings(text: str) -> list[str]:
    """`CODE file message` per warning, line numbers dropped (they drift)."""
    out = set()
    for line in text.splitlines():
        m = WARN_RE.match(line.strip())
        if m:
            out.add(f"{m.group(1)}\t{m.group(2)}\t{m.group(3).strip()}")
    return sorted(out)


def build_sims(log: Path) -> str:
    for d in ("sim_img", "sim_img_twocore"):
        subprocess.run(["rm", "-rf", str(ROOT / "build" / d)])
    res = subprocess.run(["make", "pycore-sim-img", "pycore-sim-img-twocore", "excore-fw"],
                         cwd=ROOT, capture_output=True, text=True)
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
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out-dir", default=str(DATA))
    ap.add_argument("--log-dir", default="build/gc_baseline")
    args = ap.parse_args()
    out_dir = Path(args.out_dir).resolve()
    log_dir = Path(args.log_dir).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    t0 = time.time()

    build_text = build_sims(log_dir / "sim_build.log")
    warnings = normalise_warnings(build_text)
    (out_dir / "gc_baseline_verilator_warnings.txt").write_text(
        f"# Verilator warnings of both shared simulator builds at {head}\n"
        "# code<TAB>file<TAB>message (line numbers dropped)\n" + "\n".join(warnings) + "\n",
        encoding="utf-8")

    aux_rows = []
    for step in AUX_STEPS:
        res = subprocess.run(["make", step], cwd=ROOT, capture_output=True, text=True)
        (log_dir / f"aux_{step}.log").write_text(res.stdout + res.stderr, encoding="utf-8")
        aux_rows.append([step, "pass" if res.returncode == 0 else "fail"])
        print(f"[gc_baseline] {step}: {aux_rows[-1][1]}", flush=True)
    (out_dir / "gc_baseline_aux.tsv").write_text(
        "step\tstatus\n" + "".join("\t".join(r) + "\n" for r in aux_rows), encoding="utf-8")

    tests = gc_suite.manifest()
    all_rows: list[list[str]] = []
    for name, suites, ce, lat, scope in ALL_TESTS_CONFIGS:
        names = config_tests(suites, scope, tests)
        results = gc_suite.run_tests(names, ce, lat, log_dir / name, args.jobs,
                                     plusargs=BASELINE_PLUSARGS, tests=tests)
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
