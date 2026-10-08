#!/usr/bin/env python3
"""Emit hash and equality vectors for the key specification.

The RTL unit testbench, the excore fallback testbench and the host tests
share this file once those benches land. P0 checks it from the host.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from pycore.tools.encoding import (  # noqa: E402
    TAG_BOOL,
    TAG_INT,
    TAG_LONG_STR,
    TAG_SHORT_STR,
)
from pycore.tools.keyspec import key_hash, need_payload_cmp, rich_eq  # noqa: E402


def _rows() -> list[str]:
    samples = [
        (TAG_INT, 0),
        (TAG_INT, 1),
        (TAG_INT, (1 << 64) - 1),  # -1 → hash -2
        (TAG_INT, 42),
        (TAG_BOOL, 0),
        (TAG_BOOL, 1),
        (TAG_SHORT_STR, 0x61),
        (TAG_LONG_STR, (0x12345678 << 64) | 0x1000),
        (TAG_LONG_STR, (0x12345678 << 64) | 0x2000),
    ]
    lines = ["# tag value hash eq_vs_first payload_cmp_vs_first"]
    first = samples[0]
    for tag, val in samples:
        h = key_hash(tag, val)
        eq = rich_eq(tag, val, first[0], first[1])
        pay = int(need_payload_cmp(tag, val, TAG_LONG_STR, (0x12345678 << 64) | 0x2000))
        eq_s = "none" if eq is None else str(int(eq))
        lines.append(f"{tag} {val:#x} {h:#x} {eq_s} {pay}")
    return lines


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", type=Path, default=ROOT / "build" / "key_vectors.txt")
    args = ap.parse_args()
    args.o.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(_rows()) + "\n"
    args.o.write_text(text, encoding="ascii")
    print(f"wrote {args.o} ({len(_rows()) - 1} vectors)")


if __name__ == "__main__":
    main()
