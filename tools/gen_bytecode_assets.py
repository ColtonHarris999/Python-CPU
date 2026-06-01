#!/usr/bin/env python3
"""Generate CPU memory images from a Python function's bytecode.

Strictly targets CPython 3.14: the emitted instruction words are real 3.14
opcode bytes, so `dis.opname[byte]` round-trips. The only structural lowering
is fused dual-load -> two single loads (the CPU's writeback stage can only push
one value per cycle).
"""

from __future__ import annotations

import argparse
import dis
import pathlib
import runpy
import sys
from typing import Iterable


REQUIRED_PY = (3, 14)


SUPPORTED_OPS = {
    "RESUME",
    "NOP",
    "LOAD_CONST",
    "LOAD_SMALL_INT",
    "LOAD_FAST",
    "LOAD_FAST_BORROW",
    "LOAD_FAST_LOAD_FAST",
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
    "STORE_FAST",
    "BINARY_OP",
    "RETURN_VALUE",
}

# Integer-only BINARY_OP opargs supported by the CPU. CPython 3.14 numbering:
# 0:+ 1:& 2:// 3:<< 5:* 6:% 7:| 8:** 9:>> 10:- 12:^ and in-place forms.
SUPPORTED_BINARY_OP_ARGS = {
    0,   # NB_ADD
    1,   # NB_AND
    2,   # NB_FLOOR_DIVIDE
    3,   # NB_LSHIFT
    5,   # NB_MULTIPLY
    6,   # NB_REMAINDER
    7,   # NB_OR
    8,   # NB_POWER
    9,   # NB_RSHIFT
    10,  # NB_SUBTRACT
    12,  # NB_XOR
    13,  # NB_INPLACE_ADD
    14,  # NB_INPLACE_AND
    15,  # NB_INPLACE_FLOOR_DIVIDE
    16,  # NB_INPLACE_LSHIFT
    18,  # NB_INPLACE_MULTIPLY
    19,  # NB_INPLACE_REMAINDER
    20,  # NB_INPLACE_OR
    21,  # NB_INPLACE_POWER
    22,  # NB_INPLACE_RSHIFT
    23,  # NB_INPLACE_SUBTRACT
    25,  # NB_INPLACE_XOR
}


# Opcode numbers used directly when synthesizing the lowered halves of fused
# dual-load instructions. Pinned to 3.14; checked at import-time via the
# version guard so a mismatch fails loudly rather than miscompiles.
_OP_LOAD_FAST = 84
_OP_LOAD_FAST_BORROW = 86


def _require_python_3_14() -> None:
    if sys.version_info[:2] != REQUIRED_PY:
        raise RuntimeError(
            f"gen_bytecode_assets.py targets Python {REQUIRED_PY[0]}.{REQUIRED_PY[1]} "
            f"strictly; running under "
            f"{sys.version_info.major}.{sys.version_info.minor}"
        )


def _load_function(path: pathlib.Path, function_name: str):
    namespace = runpy.run_path(str(path))
    if function_name not in namespace:
        raise ValueError(f"Function '{function_name}' not found in {path}")
    fn = namespace[function_name]
    if not callable(fn):
        raise ValueError(f"'{function_name}' in {path} is not callable")
    return fn


def _iter_supported_instructions(fn) -> Iterable[dis.Instruction]:
    for ins in dis.get_instructions(fn):
        if ins.opname == "CACHE":
            continue
        if ins.opname not in SUPPORTED_OPS:
            raise ValueError(
                f"Unsupported opcode '{ins.opname}' at offset {ins.offset}. "
                f"Supported: {sorted(SUPPORTED_OPS)}"
            )
        if ins.opname == "BINARY_OP":
            arg = 0 if ins.arg is None else ins.arg
            if arg not in SUPPORTED_BINARY_OP_ARGS:
                raise ValueError(
                    f"Unsupported BINARY_OP oparg {arg} at offset {ins.offset}. "
                    f"Supported integer args: {sorted(SUPPORTED_BINARY_OP_ARGS)}"
                )
        yield ins


def _write_hex(lines: list[str], path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # $readmemh on some Verilator versions warns on a fully empty file;
    # emit one zero word so const_mem[0] is deterministically 0.
    if not lines:
        lines = ["00000000"]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _emit_word(opcode: int, arg: int) -> str:
    if not (0 <= opcode <= 0xFF):
        raise ValueError(f"Opcode byte out of range: {opcode}")
    if not (0 <= arg <= 0xFF):
        raise ValueError(f"Instruction arg out of 8-bit range: opcode={opcode} arg={arg}")
    word = ((arg & 0xFF) << 8) | (opcode & 0xFF)
    return f"{word:04x}"


def generate_assets(
    source: pathlib.Path,
    function_name: str,
    program_hex: pathlib.Path,
    const_hex: pathlib.Path,
    expected_txt: pathlib.Path,
) -> None:
    _require_python_3_14()

    fn = _load_function(source, function_name)
    instructions = list(_iter_supported_instructions(fn))
    raw_consts = fn.__code__.co_consts

    # Compact constants table: only LOAD_CONST feeds it (negatives, ints > 255,
    # or anything else CPython didn't lower into LOAD_SMALL_INT). Indexed by
    # the original co_consts index so we can rewrite opargs.
    const_map: dict[int, int] = {}
    compact_consts: list[int] = []
    for ins in instructions:
        if ins.opname != "LOAD_CONST":
            continue
        src_idx = 0 if ins.arg is None else ins.arg
        if src_idx < 0 or src_idx >= len(raw_consts):
            raise ValueError(f"LOAD_CONST index out of range: {src_idx}")
        value = raw_consts[src_idx]
        if value is None:
            value = 0
        if not isinstance(value, int):
            raise ValueError(
                f"Constant #{src_idx} is not an int ({value!r}); only int/None supported"
            )
        if value < -(1 << 31) or value > (1 << 31) - 1:
            raise ValueError(f"Constant #{src_idx}={value} exceeds signed 32-bit range")
        if src_idx not in const_map:
            const_map[src_idx] = len(compact_consts)
            compact_consts.append(value)

    program_lines: list[str] = []
    for ins in instructions:
        arg = 0 if ins.arg is None else ins.arg

        if ins.opname == "LOAD_CONST":
            program_lines.append(_emit_word(ins.opcode, const_map[ins.arg]))
            continue

        if ins.opname == "LOAD_SMALL_INT":
            if not (0 <= arg <= 0xFF):
                raise ValueError(
                    f"LOAD_SMALL_INT literal out of 0..255: arg={arg} at offset {ins.offset}"
                )
            program_lines.append(_emit_word(ins.opcode, arg))
            continue

        if ins.opname in ("LOAD_FAST_BORROW_LOAD_FAST_BORROW", "LOAD_FAST_LOAD_FAST"):
            # Fused dual-load: high nibble is the first local index, low
            # nibble the second. Verified empirically on 3.14.3: locals
            # (a=0,b=1) with arg=1 -> indices (0, 1).
            hi = (arg >> 4) & 0xF
            lo = arg & 0xF
            single_op = (
                _OP_LOAD_FAST_BORROW
                if ins.opname == "LOAD_FAST_BORROW_LOAD_FAST_BORROW"
                else _OP_LOAD_FAST
            )
            program_lines.append(_emit_word(single_op, hi))
            program_lines.append(_emit_word(single_op, lo))
            continue

        # All other supported opcodes (RESUME, NOP, LOAD_FAST,
        # LOAD_FAST_BORROW, STORE_FAST, BINARY_OP, RETURN_VALUE) pass through
        # with the byte CPython 3.14 already chose.
        program_lines.append(_emit_word(ins.opcode, arg))

    const_lines: list[str] = []
    for value in compact_consts:
        const_lines.append(f"{value & 0xFFFFFFFF:08x}")

    expected = fn()
    if not isinstance(expected, int):
        raise ValueError(f"Function return value must be int; got {type(expected).__name__}")
    if expected < -(1 << 31) or expected > (1 << 31) - 1:
        raise ValueError(f"Expected value {expected} exceeds signed 32-bit range")

    _write_hex(program_lines, program_hex)
    _write_hex(const_lines, const_hex)
    expected_txt.parent.mkdir(parents=True, exist_ok=True)
    expected_txt.write_text(f"{expected}\n", encoding="ascii")


def main() -> None:
    _require_python_3_14()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="programs/demo_program.py")
    parser.add_argument("--function", default="managed_entry")
    parser.add_argument("--program-hex", default="programs/demo_prog.hex")
    parser.add_argument("--const-hex", default="programs/demo_consts.hex")
    parser.add_argument("--expected", default="programs/demo_expected.txt")
    args = parser.parse_args()

    generate_assets(
        source=pathlib.Path(args.source),
        function_name=args.function,
        program_hex=pathlib.Path(args.program_hex),
        const_hex=pathlib.Path(args.const_hex),
        expected_txt=pathlib.Path(args.expected),
    )


if __name__ == "__main__":
    main()
