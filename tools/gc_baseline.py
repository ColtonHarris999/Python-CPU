#!/usr/bin/env python3.14
"""Capture the G0 baseline (planning/gc_plan.md §10.2 G0).

Runs every hardware test on a checkout of `main` (no collector) with that
checkout's own pycore/tools/hw_tests.py, under the configurations CI runs
(`make test-hw`: CACHE_EN=1 MEM_LATENCY=4; `make test-caching`: cache off at
latency 1, 4 and 30, cache on at latency 30), and writes:

- `pycore/tests/data/gc_baseline_cycles.tsv`: one row per simulator run,
  `test, area, core, cache_en, mem_latency, index, kind, code, value,
  cycles` (`kind` is return, trap, or fail for a run that failed on main;
  `code` is the tag or trap code; `index` counts simulator runs within one
  test, for the few hand-written recipes that run more than one);
- `pycore/tests/data/gc_baseline_verilator_warnings.txt`: the normalised
  Verilator warnings of both shared simulator builds;
- `pycore/tests/data/gc_baseline_aux.tsv`: pass/fail of the non-hardware
  steps (host tools, RTL module testbenches, the excore CPU testbench).

    python3.14 tools/gc_baseline.py                 # worktree of origin/main
    python3.14 tools/gc_baseline.py --repo ../main  # an existing checkout

G1 compares the collector-off runs with these rows, G13 P1/P2 the
collector-on runs, G14 the warnings.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))
import hw_tests  # noqa: E402

DATA = ROOT / "pycore" / "tests" / "data"
TSV_FILE = hw_tests.BASELINE
WARN_FILE = DATA / "gc_baseline_verilator_warnings.txt"
AUX_FILE = DATA / "gc_baseline_aux.tsv"
# The configurations of `make test-hw` and `make test-caching`.
CONFIGS = [hw_tests.config("1,4")] + [hw_tests.Config(*c) for c in hw_tests.CACHING_CONFIGS]
AUX_STEPS = ["test-host", "test-rtl-modules", "excore-cpu-test"]
TSV_HEADER = ["test", "area", "core", "cache_en", "mem_latency", "index", "kind", "code",
              "value", "cycles"]
WARN_RE = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:]+):\d+:\d+: (.*)$")
LINE_RE = re.compile(r"^(PASS|FAIL)\s+(\S+)/(\S+)\s+\[(cache=(\d) lat=(\d+))\]")


def normalise_warnings(text: str) -> list[str]:
    """`CODE file message` per warning, line numbers dropped (they drift)."""
    out = set()
    for line in text.splitlines():
        m = WARN_RE.match(line.strip())
        if m:
            out.add(f"{m.group(1)}\t{m.group(2)}\t{m.group(3).strip()}")
    return sorted(out)


def rows_for(r: hw_tests.Result) -> list[dict[str, str]]:
    """Baseline-format rows of one hw_tests result."""
    base = {"test": r.test.name, "area": r.test.area, "core": r.test.core,
            "cache_en": str(r.config.cache_en), "mem_latency": str(r.config.latency)}
    if not r.passed:
        return [base | {"index": "0", "kind": "fail", "code": "-1", "value": "", "cycles": "-1"}]
    return [base | {"index": str(i), "kind": s.kind, "code": str(s.code), "value": s.value,
                    "cycles": str(s.cycles)} for i, s in enumerate(r.sims)]


def sh(cmd: list[str], cwd: pathlib.Path, log: pathlib.Path) -> int:
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    log.write_text(" ".join(cmd) + "\n\n" + res.stdout + res.stderr, encoding="utf-8")
    return res.returncode


def worktree(ref: str) -> pathlib.Path:
    path = ROOT / "build" / "gc_baseline" / "main"
    if not (path / ".git").exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "worktree", "add", "--detach", str(path), ref], cwd=ROOT, check=True)
    else:
        subprocess.run(["git", "checkout", "--detach", ref], cwd=path, check=True)
    return path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="checkout to measure (default: a worktree of --ref)")
    ap.add_argument("--ref", default="origin/main", help="commit for the default worktree")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--out-dir", default=str(DATA))
    ap.add_argument("--reuse", action="store_true",
                    help="parse the hardware-test output of an earlier run in the checkout "
                         "(build/gc_baseline/hw_*.out) instead of running again")
    ap.add_argument("--skip-aux", action="store_true", help="do not rerun the aux steps")
    args = ap.parse_args()
    repo = pathlib.Path(args.repo).resolve() if args.repo else worktree(args.ref)
    out_dir = pathlib.Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    logs = repo / "build" / "gc_baseline"
    logs.mkdir(parents=True, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True,
                          text=True, check=True).stdout.strip()
    t0 = time.time()
    py = sys.executable

    if not args.reuse:
        for d in ("sim_img", "sim_img_twocore"):
            subprocess.run(["rm", "-rf", str(repo / "build" / d)], check=True)
        rc = sh(["make", "pycore-sim-img", "pycore-sim-img-twocore", "excore-fw"], repo,
                logs / "sim_build.log")
        if rc != 0:
            raise SystemExit(f"simulator build failed; see {logs / 'sim_build.log'}")
    warnings = normalise_warnings((logs / "sim_build.log").read_text(encoding="utf-8"))
    (out_dir / WARN_FILE.name).write_text(
        f"# Verilator warnings of both shared simulator builds at {head}\n"
        "# code<TAB>file<TAB>message (line numbers dropped)\n" + "\n".join(warnings) + "\n",
        encoding="utf-8")

    runs = {"default": ["--area", "all"], "caching": ["--caching"]}
    for name, sel in runs.items():
        out = logs / f"hw_{name}.out"
        if args.reuse and out.exists():
            continue
        cmd = [py, "pycore/tools/hw_tests.py", *sel, "--jobs", str(args.jobs)]
        print(f"[gc_baseline] {' '.join(cmd)}", flush=True)
        res = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        out.write_text(res.stdout + res.stderr, encoding="utf-8")

    tests = {t.name: t for t in hw_tests.load_manifest(repo / "pycore" / "programs" / "hw_tests.toml")}
    configs = {(c.cache_en, c.latency): c for c in CONFIGS}
    rows: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for name in runs:
        for line in (logs / f"hw_{name}.out").read_text(encoding="utf-8").splitlines():
            m = LINE_RE.match(line)
            if not m or m.group(3) not in tests:
                continue
            t = tests[m.group(3)]
            cfg = configs[(int(m.group(5)), int(m.group(6)))]
            if (t.name, cfg.slug) in seen:
                continue
            seen.add((t.name, cfg.slug))
            log = repo / "build" / "hw" / t.name / f"sim-{cfg.slug}.log"
            r = hw_tests.Result(t, cfg, m.group(1) == "PASS", "", log=log)
            if r.passed:
                r.sims = hw_tests.parse_sims(r.text())
                r.passed = bool(r.sims)
            rows += rows_for(r)
    rows.sort(key=lambda r: (r["area"], r["test"], -int(r["cache_en"]), int(r["mem_latency"]),
                             int(r["index"])))

    aux_rows = []
    if args.skip_aux and (out_dir / AUX_FILE.name).exists():
        aux_rows = [ln.split("\t") for ln in (out_dir / AUX_FILE.name).read_text().splitlines()[1:]]
    else:
        for step in AUX_STEPS:
            rc = sh(["make", step, f"TEST_JOBS={args.jobs}"], repo, logs / f"aux_{step}.log")
            aux_rows.append([step, "pass" if rc == 0 else "fail"])
            print(f"[gc_baseline] {step}: {aux_rows[-1][1]}", flush=True)
    (out_dir / AUX_FILE.name).write_text(
        "step\tstatus\n" + "".join("\t".join(r) + "\n" for r in aux_rows), encoding="utf-8")

    with (out_dir / TSV_FILE.name).open("w", encoding="utf-8") as fh:
        fh.write(f"# G0 baseline at {head}; tools/gc_baseline.py (16 MB memory map)\n")
        fh.write("\t".join(TSV_HEADER) + "\n")
        for row in rows:
            fh.write("\t".join(row[k] for k in TSV_HEADER) + "\n")
    fails = [r for r in rows if r["kind"] == "fail"]
    print(f"[gc_baseline] wrote {len(rows)} rows ({len(fails)} failing on {head[:10]}) "
          f"in {time.time() - t0:.0f}s", flush=True)
    for r in fails:
        print(f"  FAIL {r['test']} cache={r['cache_en']} lat={r['mem_latency']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
