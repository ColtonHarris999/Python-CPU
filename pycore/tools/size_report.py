#!/usr/bin/env python3.14
"""W-8 / A8: per-region occupancy vs hardware ceilings.

Build a compiler-resident image (``img_compile_eval_expr``) and print ROM
slots, code-RAM package slots, and static heap bytes against the limits in
``encoding.py`` / ``pycore_defs.svh``. Exit 1 if any region overflows.

``make pycore-size-report`` is the A8 gate (compiler_design.md step K).
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from encoding import (  # noqa: E402
    CODE_RAM_SLOT_BASE,
    CODE_RAM_SLOT_LIMIT,
    CODE_RAM_SLOTS,
    HEAP_BASE,
    HEAP_LIMIT,
)
from image_from_source import build_image_from_source  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / "pycore" / "programs" / "img_compile_eval_expr.py"


class Region:
    """One occupancy row: used vs a hardware ceiling."""

    def __init__(self, name: str, used: int, capacity: int, unit: str) -> None:
        self.name = name
        self.used = used
        self.capacity = capacity
        self.unit = unit

    @property
    def remaining(self) -> int:
        return self.capacity - self.used

    @property
    def ok(self) -> bool:
        return self.used <= self.capacity


class SizeReport:
    """Measured occupancy for one compiler-resident image."""

    def __init__(self, source: pathlib.Path, regions: list[Region]) -> None:
        self.source = source
        self.regions = regions

    @property
    def ok(self) -> bool:
        return all(region.ok for region in self.regions)


def collect_size_report(
    source: pathlib.Path | None = None,
) -> SizeReport:
    """Build ``source`` and return ROM / code-RAM / heap occupancy."""
    path = pathlib.Path(source) if source is not None else DEFAULT_SOURCE
    image = build_image_from_source(path)
    rom_used = len(image.program_slots)
    ram_used = len(image.code_ram_slots)
    heap_used = image.heap_init_ptr - HEAP_BASE
    if image.code_ram_init_slot != CODE_RAM_SLOT_BASE + ram_used:
        raise RuntimeError(
            "CODE_RAM_INIT_SLOT "
            f"{image.code_ram_init_slot} != base {CODE_RAM_SLOT_BASE} "
            f"+ {ram_used} package slots"
        )
    regions = [
        Region("Code ROM", rom_used, CODE_RAM_SLOT_BASE, "slots"),
        Region("Code RAM (compiler)", ram_used, CODE_RAM_SLOTS, "slots"),
        Region("Heap (static image)", heap_used, HEAP_LIMIT - HEAP_BASE, "bytes"),
    ]
    return SizeReport(path, regions)


def format_report(report: SizeReport) -> str:
    """Render a fixed-width table plus remaining compiled-output room."""
    lines = [
        f"PyCore size report  ({report.source.name})",
        f"{'region':<24} {'used':>10} {'capacity':>10} {'remain':>10}  status",
        f"{'-' * 24} {'-' * 10} {'-' * 10} {'-' * 10}  ------",
    ]
    for region in report.regions:
        status = "ok" if region.ok else "OVERFLOW"
        lines.append(
            f"{region.name:<24} {region.used:>10} {region.capacity:>10} "
            f"{region.remaining:>10}  {status}"
        )
    ram = report.regions[1]
    lines.append("")
    lines.append(
        f"compiled-output headroom: {ram.remaining} code-RAM slots "
        f"(CODE_RAM_SLOT_LIMIT={CODE_RAM_SLOT_LIMIT})"
    )
    if ram.remaining < ram.used:
        lines.append(
            f"self-host: blocked (need {ram.used} output slots, "
            f"have {ram.remaining} headroom)"
        )
    else:
        lines.append(
            f"self-host: unblocked ({ram.remaining} headroom "
            f">= {ram.used} package)"
        )
    if not report.ok:
        lines.append("FAIL: a region exceeds its hardware ceiling (A8)")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=pathlib.Path,
        default=DEFAULT_SOURCE,
        help="compiler-resident image source (default: img_compile_eval_expr.py)",
    )
    args = parser.parse_args(argv)
    report = collect_size_report(args.source)
    sys.stdout.write(format_report(report))
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
