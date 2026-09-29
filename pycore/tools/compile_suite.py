#!/usr/bin/env python3.14
"""Device-compile suite: compile on PyCore, run on PyCore, compare with CPython.

Each program under ``pycore/programs/compile_suite/`` is handed to the hart as
source text (``pycore_cli.py run``, the same path as ``make run-file``). The
resident on-device ``compile()`` builds it, ``exec()`` runs it, and its printed
output must match host CPython 3.14 compiling and running the same file.
Together the programs cover every grammar tier the on-device compiler accepts
and every opcode family it emits.

The ~460 host-compiled ``pycore-img-*`` fixtures test the hardware on CPython's
own bytecode. This suite tests the other half: the firmware compiler's output,
executed on the hart.

Usage::

    python3.14 pycore/tools/compile_suite.py            # all programs, 2 jobs
    python3.14 pycore/tools/compile_suite.py --jobs 4 cs_starred
    make pycore-compile-suite TEST_JOBS=4
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import pathlib
import subprocess
import sys
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE_DIR = REPO_ROOT / "pycore" / "programs" / "compile_suite"
CLI = REPO_ROOT / "pycore" / "tools" / "pycore_cli.py"
ENSURE_SIM = REPO_ROOT / "tools" / "ensure_sim.py"
DEFAULT_BUILD = REPO_ROOT / "build" / "compile_suite"
# Generous: the largest program compiles in roughly 60M cycles.
DEFAULT_MAX_CYCLES = 400_000_000


def discover(names: list[str]) -> list[pathlib.Path]:
    programs = sorted(SUITE_DIR.glob("*.py"))
    if not names:
        return programs
    picked = []
    for name in names:
        stem = pathlib.Path(name).stem
        match = [p for p in programs if p.stem == stem or p.stem == f"cs_{stem}"]
        if not match:
            raise SystemExit(f"compile_suite: no program named {name!r} in {SUITE_DIR}")
        picked.extend(match)
    return picked


def run_one(
    path: pathlib.Path, build: pathlib.Path, extra: list[str], max_cycles: int
) -> dict:
    work = build / path.stem
    work.mkdir(parents=True, exist_ok=True)
    report_path = work / "report.json"
    if report_path.exists():
        report_path.unlink()
    cmd = [
        sys.executable, str(CLI), "run", str(path),
        "--no-progress",
        "--build-dir", str(work),
        "--json", str(report_path),
        "--max-cycles", str(max_cycles),
        *extra,
    ]
    start = time.monotonic()
    proc = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    elapsed = time.monotonic() - start
    log = work / "suite.log"
    log.write_text(proc.stdout + proc.stderr, encoding="utf-8")
    result = {
        "name": path.stem,
        "rc": proc.returncode,
        "verdict": "ERROR",
        "detail": "",
        "compile_cycles": None,
        "run_cycles": None,
        "compile_heap": None,
        "wall_s": elapsed,
        "log": str(log.relative_to(REPO_ROOT)),
    }
    if report_path.is_file():
        report = json.loads(report_path.read_text(encoding="utf-8"))
        result["verdict"] = report.get("verdict", "ERROR")
        result["detail"] = report.get("detail", "")
        dev = report.get("device") or {}
        phases = dev.get("phases") or {}
        result["compile_cycles"] = (phases.get("compile") or {}).get("cycle")
        result["run_cycles"] = (phases.get("run") or {}).get("cycle")
        result["compile_heap"] = dev.get("heap_compile")
    else:
        tail = (proc.stdout + proc.stderr).strip().splitlines()[-3:]
        result["detail"] = " | ".join(tail)
    return result


def _fmt(n: object) -> str:
    return f"{n:,}" if isinstance(n, int) else "-"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("programs", nargs="*", help="program stems (default: all)")
    ap.add_argument("--jobs", "-j", type=int, default=2)
    ap.add_argument("--build-dir", default=str(DEFAULT_BUILD))
    ap.add_argument("--max-cycles", type=int, default=DEFAULT_MAX_CYCLES)
    ap.add_argument("--cache-en", type=int, choices=(0, 1), default=None)
    ap.add_argument("--mem-latency", type=int, default=None)
    ap.add_argument("--list", action="store_true", help="list programs and exit")
    args = ap.parse_args(argv)

    programs = discover(args.programs)
    if args.list:
        for p in programs:
            print(p.relative_to(REPO_ROOT))
        return 0
    if not programs:
        print(f"compile_suite: no programs in {SUITE_DIR}", file=sys.stderr)
        return 1

    # Build the shared two-core simulator once, not once per worker.
    subprocess.run([sys.executable, str(ENSURE_SIM), "twocore"], cwd=REPO_ROOT, check=True)

    extra: list[str] = []
    if args.cache_en is not None:
        extra += ["--cache-en", str(args.cache_en)]
    if args.mem_latency is not None:
        extra += ["--mem-latency", str(args.mem_latency)]
    build = pathlib.Path(args.build_dir)
    if not build.is_absolute():
        build = REPO_ROOT / build

    print(f"compile_suite: {len(programs)} program(s), {args.jobs} job(s)", flush=True)
    results: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {
            pool.submit(run_one, p, build, extra, args.max_cycles): p for p in programs
        }
        for fut in concurrent.futures.as_completed(futures):
            r = fut.result()
            results.append(r)
            print(
                f"  {r['verdict']:<11} {r['name']:<22} "
                f"compile {_fmt(r['compile_cycles']):>12}  run {_fmt(r['run_cycles']):>10}  "
                f"({r['wall_s']:.0f} s)",
                flush=True,
            )

    results.sort(key=lambda r: r["name"])
    failed = [r for r in results if r["verdict"] != "PASS"]
    print()
    print(f"{'program':<22} {'verdict':<11} {'compile cycles':>15} {'run cycles':>12} {'compile heap':>13}")
    for r in results:
        print(
            f"{r['name']:<22} {r['verdict']:<11} {_fmt(r['compile_cycles']):>15} "
            f"{_fmt(r['run_cycles']):>12} {_fmt(r['compile_heap']):>13}"
        )
    print()
    if failed:
        for r in failed:
            print(f"FAIL {r['name']}: {r['verdict']} {r['detail']}  (log: {r['log']})")
        print(f"compile_suite: {len(failed)} of {len(results)} failed")
        return 1
    print(f"compile_suite: all {len(results)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
