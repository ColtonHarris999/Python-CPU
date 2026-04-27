#!/usr/bin/env python3
"""Generate CPU memory images from a Python function's bytecode."""

from __future__ import annotations

import argparse
import dis
import pathlib
import runpy
from typing import Iterable


SUPPORTED_OPS = {
    "RESUME",
    "NOP",
    "LOAD_CONST",
    "LOAD_FAST",
    "STORE_FAST",
    "BINARY_OP",
    "RETURN_VALUE",
}


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
        yield ins


def _write_hex(lines: list[str], path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def generate_assets(
    source: pathlib.Path,
    function_name: str,
    program_hex: pathlib.Path,
    const_hex: pathlib.Path,
    expected_txt: pathlib.Path,
) -> None:
    fn = _load_function(source, function_name)
    instructions = list(_iter_supported_instructions(fn))
    raw_consts = fn.__code__.co_consts

    # Build a compact integer-only constants table and rewrite LOAD_CONST opargs
    # so indices remain valid for the CPU's simple integer constant memory.
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
            arg = const_map[arg]
        if arg < 0 or arg > 0xFF:
            raise ValueError(f"Instruction arg out of 8-bit range: {ins.opname} arg={arg}")

        # 16-bit instruction word: [15:8]=oparg, [7:0]=opcode.
        word = ((arg & 0xFF) << 8) | (ins.opcode & 0xFF)
        program_lines.append(f"{word:04x}")

    const_lines: list[str] = []
    for i, value in enumerate(compact_consts):
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
