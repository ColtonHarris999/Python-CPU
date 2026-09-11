#!/usr/bin/env python3
"""Build the shared tb_container simulator if it is missing.

Image / container / two-core Makefile targets call this so they can reuse one
Verilator binary. A lock directory makes `make -j` safe when many tests race
the first compile.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"

KINDS = {
    "img": (
        BUILD / "sim_img" / "Vtb_container",
        "pycore-sim-img",
        BUILD / "sim_img.lockd",
    ),
    "twocore": (
        BUILD / "sim_img_twocore" / "Vtb_container",
        "pycore-sim-img-twocore",
        BUILD / "sim_img_twocore.lockd",
    ),
}


def _ready(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in KINDS:
        print(f"usage: {sys.argv[0]} img|twocore", file=sys.stderr)
        return 2
    bin_path, target, lock = KINDS[sys.argv[1]]
    BUILD.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + 900
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            if time.time() > deadline:
                print(f"timeout waiting for {lock}", file=sys.stderr)
                return 1
            time.sleep(0.2)
    try:
        # Always ask make; it no-ops when RTL/TB mtimes are unchanged.
        subprocess.check_call(["make", target], cwd=ROOT)
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass
    return 0 if _ready(bin_path) else 1


if __name__ == "__main__":
    raise SystemExit(main())
