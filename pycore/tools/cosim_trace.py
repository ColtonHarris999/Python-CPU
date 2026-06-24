#!/usr/bin/env python3
"""Summarize PyCore cosimulation traces."""

from __future__ import annotations

import argparse
import collections
import pathlib


def summarize(trace_path: pathlib.Path) -> str:
    opcodes: collections.Counter[str] = collections.Counter()
    traps: collections.Counter[str] = collections.Counter()
    units: collections.Counter[str] = collections.Counter()
    cycles = 0

    for raw_line in trace_path.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = dict(
            item.split("=", 1)
            for item in line.split()
            if "=" in item
        )
        cycles += 1
        if "opcode" in fields:
            opcodes[fields["opcode"]] += 1
        if fields.get("trap", "0") != "0":
            traps[fields.get("trap_code", "UNKNOWN")] += 1
        if "unit" in fields:
            units[fields["unit"]] += 1

    opcode_count = sum(opcodes.values())
    trap_count = sum(traps.values())
    cpo = (cycles / opcode_count) if opcode_count else 0.0
    trap_rate = (trap_count / opcode_count) if opcode_count else 0.0

    lines = [
        f"cycles={cycles}",
        f"opcodes={opcode_count}",
        f"cpo={cpo:.3f}",
        f"trap_rate={trap_rate:.3f}",
        "unit_utilization:",
    ]
    for unit, count in sorted(units.items()):
        lines.append(f"  {unit}: {count / cycles if cycles else 0.0:.3f}")
    if traps:
        lines.append("traps:")
        for code, count in sorted(traps.items()):
            lines.append(f"  {code}: {count}")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=pathlib.Path)
    args = parser.parse_args()
    print(summarize(args.trace))


if __name__ == "__main__":
    main()
