#!/usr/bin/env python3.14
"""Generate the direct END_FOR stack-pop fixture.

Natural CPython 3.14 FOR_ITER exhaustion skips END_FOR and lands at POP_ITER,
so this raw stream executes END_FOR directly to prove its POP_TOP-equivalent
hardware path.

Regenerate with:
    python3.14 pycore/tools/gen_for_iter_fixtures.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from encoding import format_imem_slot  # noqa: E402
from image_from_source import write_program_hex  # noqa: E402

PROGRAMS_DIR = pathlib.Path(__file__).resolve().parent.parent / "programs"

OP_END_FOR = 9
OP_RETURN_VALUE = 35
OP_LOAD_SMALL_INT = 94


def main() -> None:
    slots = [
        format_imem_slot(OP_LOAD_SMALL_INT, 7),
        format_imem_slot(OP_LOAD_SMALL_INT, 9),
        format_imem_slot(OP_END_FOR, 0),
        format_imem_slot(OP_RETURN_VALUE, 0),
    ]
    output = PROGRAMS_DIR / "for_iter_end_for.hex"
    write_program_hex(output, slots)
    print("Wrote", output)


if __name__ == "__main__":
    main()
