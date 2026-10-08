#!/usr/bin/env python3
"""Accelerator speedup report skeleton (accelerator_split_plan.md §12.3).

P0 records the profile names and writes an empty report so later phases
can fill cycles. It does not run the simulator.
"""

from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROFILES = (
    "all-on",
    "no-ca",
    "no-stracc",
    "no-codc",
    "no-gic",
    "gc-off",
    "gc-engine",
    "gc-soft",
    "all-off",
)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "accel")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    csv_path = args.out / "report.csv"
    md_path = args.out / "report.md"
    header = "profile,rom,latency,attach,test,cycles,excore_traps\n"
    csv_path.write_text(header, encoding="ascii")
    lines = [
        "# Accelerator report",
        "",
        "P0 skeleton. No matrix has been run. Profiles:",
        "",
    ]
    lines += [f"- `{name}`" for name in PROFILES]
    lines += ["", "Speedup is `cycles(profile with the unit off) / cycles(all-on)`.", ""]
    md_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {csv_path} and {md_path}")


if __name__ == "__main__":
    main()
