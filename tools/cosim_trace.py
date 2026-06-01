#!/usr/bin/env python3
"""Tiny helper to compare PyCore and Python result traces."""

from __future__ import annotations

import argparse
import pathlib
import sys


def read_lines(path: pathlib.Path) -> list[str]:
    if not path.exists():
        raise FileNotFoundError(path)
    return [line.rstrip("\\n") for line in path.read_text(encoding="utf-8").splitlines()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-trace", required=True)
    parser.add_argument("--pycore-trace", required=True)
    args = parser.parse_args()

    py_lines = read_lines(pathlib.Path(args.python_trace))
    hw_lines = read_lines(pathlib.Path(args.pycore_trace))

    mismatch_idx = None
    for idx, (py, hw) in enumerate(zip(py_lines, hw_lines)):
        if py != hw:
            mismatch_idx = idx
            break

    if mismatch_idx is None and len(py_lines) == len(hw_lines):
        print("PASS: traces match")
        return

    if mismatch_idx is None:
        mismatch_idx = min(len(py_lines), len(hw_lines))

    py_val = py_lines[mismatch_idx] if mismatch_idx < len(py_lines) else "<eof>"
    hw_val = hw_lines[mismatch_idx] if mismatch_idx < len(hw_lines) else "<eof>"
    print(f"FAIL: mismatch at line {mismatch_idx + 1}")
    print(f"  python: {py_val}")
    print(f"  pycore: {hw_val}")
    sys.exit(1)


if __name__ == "__main__":
    main()
