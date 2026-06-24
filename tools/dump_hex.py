#!/usr/bin/env python3
"""Pretty-print a $readmemh hex file as indexed memory contents."""

from __future__ import annotations

import argparse
import pathlib


def dump_hex(path: pathlib.Path, label: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"Hex file not found: {path}")

    lines = path.read_text(encoding="ascii").splitlines()
    print(f"=== {label}: {path} ===")

    addr = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if line.startswith("@"):
            addr = int(line[1:], 16)
            continue
        print(f"{addr:08x}: {line}")
        addr += 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", required=True, help="Path to readmemh-compatible hex file")
    parser.add_argument("--label", default="Memory image", help="Label printed in header")
    args = parser.parse_args()
    dump_hex(pathlib.Path(args.path), args.label)


if __name__ == "__main__":
    main()
