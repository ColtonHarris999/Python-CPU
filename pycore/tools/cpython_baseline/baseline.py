#!/usr/bin/env python3.14
"""Measure CPython 3.14 on an adjustable simulated machine.

Callgrind simulates the caches and the branch predictor. A simple-core
model turns those counts into cycles and splits each program into

  compile     source to bytecode (cold, and a second compile)
  interpret   the dispatch edge: fetch the next code unit, decode it,
              indirect-jump into the handler
  run         everything else in the cold exec (inline opcode bodies
              and the C helpers they call)

``--machine`` is a preset name or a TOML file. Sizes, associativity, line
size, hit latencies, memory latency, and the branch penalty are flags, so
a sweep does not need a new file.

    python3.14 pycore/tools/cpython_baseline/baseline.py --suite --machine pycore
    python3.14 pycore/tools/cpython_baseline/baseline.py prog.py --machine skylake --llc-bytes 1048576
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow ``python3.14 path/to/baseline.py`` without PYTHONPATH.
_TOOLS = Path(__file__).resolve().parents[1]
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from cpython_baseline.machine import apply_overrides, load_machine, preset_names  # noqa: E402
from cpython_baseline.report import render_program, render_suite  # noqa: E402
from cpython_baseline.runner import measure, python_identity  # noqa: E402

_BENCH = Path(__file__).resolve().parent / "benchmarks"


def _overrides(args: argparse.Namespace) -> dict:
    return {
        "l1i_bytes": args.l1i_bytes,
        "l1d_bytes": args.l1d_bytes,
        "llc_bytes": args.llc_bytes,
        "l1i_assoc": args.l1i_assoc,
        "l1d_assoc": args.l1d_assoc,
        "llc_assoc": args.llc_assoc,
        "line_bytes": args.line_bytes,
        "l1i_hit": args.l1i_hit,
        "l1d_hit": args.l1d_hit,
        "llc_hit": args.llc_hit,
        "mem_latency": args.mem_latency,
        "branch_penalty": args.branch_penalty,
        "mhz": args.mhz,
    }


def _programs(args: argparse.Namespace) -> list[Path]:
    chosen = [Path(p) for p in args.program]
    if args.suite:
        chosen.extend(sorted(_BENCH.glob("*.py")))
    return chosen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("program", nargs="*", help="Python files to measure")
    parser.add_argument("--suite", action="store_true", help="Also run the built-in benchmarks")
    parser.add_argument("--machine", default="pycore", help="Preset name or path to a TOML spec")
    parser.add_argument("--list-machines", action="store_true")
    parser.add_argument("--json", help="Write the full record to this path")
    parser.add_argument("--work", default="build/cpython_baseline", help="Where the marker library is built")
    parser.add_argument("--cold-only", action="store_true", help="Skip the warm compile and warm exec")
    parser.add_argument("--l1i-bytes", type=int)
    parser.add_argument("--l1d-bytes", type=int)
    parser.add_argument("--llc-bytes", type=int)
    parser.add_argument("--l1i-assoc", type=int)
    parser.add_argument("--l1d-assoc", type=int)
    parser.add_argument("--llc-assoc", type=int)
    parser.add_argument("--line-bytes", type=int)
    parser.add_argument("--l1i-hit", type=int)
    parser.add_argument("--l1d-hit", type=int)
    parser.add_argument("--llc-hit", type=int)
    parser.add_argument("--mem-latency", type=int, help="Full memory latency, in cycles, including the LLC hit")
    parser.add_argument("--branch-penalty", type=int)
    parser.add_argument("--mhz", type=float, help="Spec clock used only for the simulated-time column")
    args = parser.parse_args(argv)

    if args.list_machines:
        for name in preset_names():
            machine = load_machine(name)
            print(f"{name:<16} {machine.description}")
        return 0

    machine = apply_overrides(load_machine(args.machine), _overrides(args))
    programs = _programs(args)
    if not programs:
        parser.error("give a Python file, or --suite for the built-in benchmarks")
    records = []
    for program in programs:
        record = measure(program, machine, Path(args.work), cold_only=args.cold_only)
        records.append(record)
        print(render_program(record, machine.to_json()))
        print()
    if len(records) > 1:
        print(render_suite(records, machine.to_json()))

    identity = python_identity()
    identity["hash_seed"] = "0"
    payload = {
        "schema_version": 1,
        "machine": machine.to_json(),
        "python": identity,
        "programs": records,
    }
    if args.json:
        path = Path(args.json)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return 0 if all(r.get("status") == "ok" for r in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
