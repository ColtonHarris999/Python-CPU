#!/usr/bin/env python3
"""Preprocess CPython 3.14 bytecode for the PyCore hardware prototype."""

from __future__ import annotations

import argparse
import dis
import importlib.util
import pathlib
import struct
import sys
from dataclasses import dataclass
from typing import Iterable


REQUIRED_PY = (3, 14)

TAG_UNINITIALIZED = 0b000
TAG_INT = 0b001
TAG_FLOAT = 0b010
TAG_BOOL = 0b011
TAG_PTR = 0b100
TAG_OBJECT = 0b101
TAG_SHORT_STR = 0b110
TAG_LONG_STR = 0b111

SHORT_STR_MAX_BYTES = 15
SHORT_STR_SIZE_SHIFT = 124
SHORT_STR_DATA_SHIFT = 4
STRING_MEM_BYTES = 65536
STRING_RUNTIME_BASE = 16384

SUPPORTED_OPS = {
    "RESUME",
    "CACHE",
    "EXTENDED_ARG",
    "LOAD_FAST",
    "LOAD_FAST_BORROW",
    "STORE_FAST",
    "LOAD_SMALL_INT",
    "LOAD_CONST",
    "POP_TOP",
    "COPY",
    "SWAP",
    "BINARY_OP",
    "UNARY_NEGATIVE",
    "UNARY_POSITIVE",
    "UNARY_INVERT",
    "UNARY_NOT",
    "COMPARE_OP",
    "JUMP_FORWARD",
    "JUMP_BACKWARD",
    "POP_JUMP_IF_TRUE",
    "POP_JUMP_IF_FALSE",
    "JUMP_IF_TRUE_OR_POP",
    "JUMP_IF_FALSE_OR_POP",
    "NOT_TAKEN",
    "POP_ITER",
    "CALL",
    "RETURN_VALUE",
}

SUPPORTED_BINARY_ARGS = {
    0, 13,   # add
    1, 14,   # and
    2, 15,   # floor divide
    3, 16,   # left shift
    5, 18,   # multiply
    6, 19,   # remainder
    7, 20,   # or
    8, 21,   # power
    9, 22,   # right shift
    10, 23,  # subtract
    11, 24,  # true divide
    12, 25,  # xor
}


@dataclass(frozen=True)
class EmittedInstruction:
    opcode: int
    arg: int
    source_offset: int
    opname: str


def require_python_3_14() -> None:
    if sys.version_info[:2] != REQUIRED_PY:
        raise RuntimeError(
            "PyCore preprocessing is pinned to CPython "
            f"{REQUIRED_PY[0]}.{REQUIRED_PY[1]}; running "
            f"{sys.version_info.major}.{sys.version_info.minor}"
        )


def load_function(source: pathlib.Path, function_name: str):
    spec = importlib.util.spec_from_file_location("_pycore_input", source)
    if spec is None or spec.loader is None:
        raise ValueError(f"Unable to import {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fn = getattr(module, function_name, None)
    if not callable(fn):
        raise ValueError(f"Function '{function_name}' not found in {source}")
    return fn


def iter_filtered_instructions(fn) -> Iterable[dis.Instruction]:
    for ins in dis.get_instructions(fn, show_caches=True):
        if ins.opname == "CACHE":
            continue
        if ins.opname == "EXTENDED_ARG":
            # CPython's disassembler has already folded the prefix into the
            # following Instruction.arg; the fetch stage also supports raw
            # EXTENDED_ARG for hand-written streams.
            continue
        if ins.opname not in SUPPORTED_OPS:
            raise ValueError(
                f"Unsupported opcode {ins.opname!r} at bytecode offset {ins.offset}"
            )
        if ins.opname == "BINARY_OP" and (ins.arg or 0) not in SUPPORTED_BINARY_ARGS:
            raise ValueError(
                f"Unsupported BINARY_OP oparg {ins.arg} at bytecode offset {ins.offset}"
            )
        yield ins


def emit_instruction_words(instructions: Iterable[dis.Instruction]) -> list[EmittedInstruction]:
    emitted: list[EmittedInstruction] = []
    for ins in instructions:
        arg = ins.arg or 0
        if not 0 <= arg < (1 << 32):
            raise ValueError(f"Instruction argument exceeds 32 bits: {ins}")
        emitted.append(
            EmittedInstruction(
                opcode=ins.opcode,
                arg=arg,
                source_offset=ins.offset,
                opname=ins.opname,
            )
        )
    return emitted


def float_bits(value: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", value))[0]


class StringHeapBuilder:
    """Builds an initialized long-string memory image for hardware."""

    def __init__(self) -> None:
        self.next_addr = 0
        self.image: dict[int, int] = {}

    def allocate(self, data: bytes) -> int:
        if not data:
            return 0

        addr = self.next_addr
        end = addr + len(data)
        if end > STRING_RUNTIME_BASE:
            raise ValueError(
                "Long-string constants exceed reserved string-constant memory "
                f"region (used {end} bytes, limit {STRING_RUNTIME_BASE})"
            )

        for offset, byte in enumerate(data):
            self.image[addr + offset] = byte
        self.next_addr = end
        return addr


# Architectural value is now a 128-bit field carrying a 3-bit tag, i.e. a
# 131-bit entry. INT keeps a 64-bit signed fast path sign-extended into the
# upper 64 bits; FLOAT/BOOL live in the low 64 bits with the rest zero.
VAL_WIDTH = 128
VAL_MASK = (1 << VAL_WIDTH) - 1
ENTRY_HEX_DIGITS = (3 + VAL_WIDTH + 3) // 4  # ceil(131/4) == 33

# Instruction memory slot: 40-bit folded word, zero-padded to one 8-byte slot.
IMEM_SLOT_BITS = 64
IMEM_SLOT_HEX_DIGITS = IMEM_SLOT_BITS // 4  # 16


def _encode_short_string(data: bytes) -> int:
    payload = 0
    for idx, byte in enumerate(data):
        shift = SHORT_STR_DATA_SHIFT + (SHORT_STR_MAX_BYTES - 1 - idx) * 8
        payload |= int(byte) << shift
    payload |= (len(data) & 0xF) << SHORT_STR_SIZE_SHIFT
    return payload


def tag_constant(value: object, string_heap: StringHeapBuilder) -> tuple[int, int]:
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    if isinstance(value, int):
        # Two's-complement masked to 128 bits sign-extends negatives correctly.
        return TAG_INT, value & VAL_MASK
    if isinstance(value, float):
        return TAG_FLOAT, float_bits(value)
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        if len(encoded) <= SHORT_STR_MAX_BYTES:
            return TAG_SHORT_STR, _encode_short_string(encoded)
        if len(encoded) > ((1 << 64) - 1):
            raise ValueError("String constant exceeds 64-bit length field")
        addr = string_heap.allocate(encoded)
        return TAG_LONG_STR, ((len(encoded) & ((1 << 64) - 1)) << 64) | (addr & ((1 << 64) - 1))
    return TAG_OBJECT, 0


def format_entry(tag: int, value: int) -> str:
    entry = ((tag & 0x7) << VAL_WIDTH) | (value & VAL_MASK)
    return f"{entry:0{ENTRY_HEX_DIGITS}x}"


def write_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="ascii")


def write_program_hex(path: pathlib.Path, instructions: Iterable[EmittedInstruction]) -> None:
    lines = [
        f"{((ins.arg & 0xffffffff) << 8) | ins.opcode:0{IMEM_SLOT_HEX_DIGITS}x}"
        for ins in instructions
    ]
    write_text(path, "\n".join(lines) + ("\n" if lines else ""))


def write_const_hex(
    path: pathlib.Path,
    consts: tuple[object, ...],
    string_heap: StringHeapBuilder,
) -> None:
    lines = [format_entry(*tag_constant(value, string_heap)) for value in consts]
    if not lines:
        lines = [format_entry(TAG_UNINITIALIZED, 0)]
    write_text(path, "\n".join(lines) + "\n")


def write_string_hex(path: pathlib.Path, string_heap: StringHeapBuilder) -> None:
    if not string_heap.image:
        write_text(path, "00\n")
        return

    lines: list[str] = []
    current_addr = -1
    for addr in sorted(string_heap.image.keys()):
        if addr < 0 or addr >= STRING_MEM_BYTES:
            raise ValueError(f"String address {addr} is outside string memory")
        if addr != current_addr + 1:
            lines.append(f"@{addr:x}")
        lines.append(f"{string_heap.image[addr]:02x}")
        current_addr = addr

    write_text(path, "\n".join(lines) + "\n")


def inline_cache_entries() -> list[int]:
    entries = getattr(dis, "_inline_cache_entries", None)
    if entries is None:
        return [0] * 256
    return [int(entries[i]) if i < len(entries) else 0 for i in range(256)]


def write_cache_map(path: pathlib.Path) -> None:
    lines = [f"{count:x}" for count in inline_cache_entries()]
    write_text(path, "\n".join(lines) + "\n")


def merge_numeric(tag_a: int, tag_b: int, op_arg: int) -> int:
    if op_arg in (0, 13) and tag_a in (TAG_SHORT_STR, TAG_LONG_STR) and tag_b in (TAG_SHORT_STR, TAG_LONG_STR):
        # Hardware resolves short-vs-long at runtime from operand sizes.
        return TAG_LONG_STR
    if tag_a in (TAG_UNINITIALIZED, TAG_OBJECT) or tag_b in (TAG_UNINITIALIZED, TAG_OBJECT):
        return TAG_OBJECT
    if op_arg in (11, 24):
        return TAG_FLOAT
    if tag_a == TAG_FLOAT or tag_b == TAG_FLOAT:
        return TAG_FLOAT
    if tag_a == TAG_BOOL and tag_b == TAG_BOOL and op_arg in (1, 7, 12, 14, 20, 25):
        return TAG_BOOL
    return TAG_INT


def infer_types(fn, instructions: list[EmittedInstruction]) -> tuple[dict[str, int], list[str]]:
    local_names = list(fn.__code__.co_varnames)
    var_tags = {name: TAG_UNINITIALIZED for name in local_names}
    stack: list[int] = []
    warnings: list[str] = []

    for ins in instructions:
        if ins.opname == "LOAD_CONST":
            const_value = fn.__code__.co_consts[ins.arg]
            if isinstance(const_value, str):
                encoded = const_value.encode("utf-8")
                tag = TAG_SHORT_STR if len(encoded) <= SHORT_STR_MAX_BYTES else TAG_LONG_STR
            else:
                tag, _ = tag_constant(const_value, StringHeapBuilder())
            stack.append(tag)
        elif ins.opname == "LOAD_SMALL_INT":
            stack.append(TAG_INT)
        elif ins.opname in ("LOAD_FAST", "LOAD_FAST_BORROW"):
            name = local_names[ins.arg] if ins.arg < len(local_names) else f"local_{ins.arg}"
            stack.append(var_tags.get(name, TAG_OBJECT))
        elif ins.opname == "STORE_FAST":
            name = local_names[ins.arg] if ins.arg < len(local_names) else f"local_{ins.arg}"
            var_tags[name] = stack.pop() if stack else TAG_OBJECT
        elif ins.opname == "POP_TOP" or ins.opname == "POP_ITER":
            if stack:
                stack.pop()
        elif ins.opname == "COPY":
            idx = ins.arg or 0
            stack.append(stack[-idx] if 0 < idx <= len(stack) else TAG_OBJECT)
        elif ins.opname == "SWAP":
            idx = ins.arg or 0
            if 0 < idx <= len(stack):
                stack[-1], stack[-idx] = stack[-idx], stack[-1]
        elif ins.opname == "BINARY_OP":
            rhs = stack.pop() if stack else TAG_OBJECT
            lhs = stack.pop() if stack else TAG_OBJECT
            result_tag = merge_numeric(lhs, rhs, ins.arg)
            if result_tag == TAG_OBJECT:
                warnings.append(
                    f"OBJECT-typed value feeds BINARY_OP at bytecode offset {ins.source_offset}"
                )
            stack.append(result_tag)
        elif ins.opname == "COMPARE_OP":
            if stack:
                stack.pop()
            if stack:
                stack.pop()
            stack.append(TAG_BOOL)
        elif ins.opname in ("UNARY_NEGATIVE", "UNARY_POSITIVE", "UNARY_INVERT", "UNARY_NOT"):
            operand = stack.pop() if stack else TAG_OBJECT
            stack.append(TAG_BOOL if ins.opname == "UNARY_NOT" else operand)
        elif ins.opname.startswith("POP_JUMP"):
            if stack:
                stack.pop()
        elif ins.opname == "CALL":
            argc = ins.arg or 0
            for _ in range(min(argc, len(stack))):
                stack.pop()
            stack.append(TAG_OBJECT)

    return var_tags, warnings


def write_types(path: pathlib.Path, var_tags: dict[str, int], warnings: list[str]) -> None:
    tag_names = {
        TAG_UNINITIALIZED: "UNINITIALIZED",
        TAG_INT: "INT",
        TAG_FLOAT: "FLOAT",
        TAG_BOOL: "BOOL",
        TAG_PTR: "PTR",
        TAG_OBJECT: "OBJECT",
        TAG_SHORT_STR: "SHORT_STR",
        TAG_LONG_STR: "LONG_STR",
    }
    lines = [f"{name}: {tag_names.get(tag, 'RESERVED')}" for name, tag in sorted(var_tags.items())]
    if warnings:
        lines.append("")
        lines.append("# warnings")
        lines.extend(warnings)
    write_text(path, "\n".join(lines) + "\n")


def preprocess(
    source: pathlib.Path,
    function_name: str,
    program_hex: pathlib.Path,
    const_hex: pathlib.Path,
    string_hex: pathlib.Path,
    types_path: pathlib.Path,
    cache_map: pathlib.Path,
) -> None:
    require_python_3_14()
    fn = load_function(source, function_name)
    instructions = emit_instruction_words(iter_filtered_instructions(fn))
    var_tags, warnings = infer_types(fn, instructions)
    string_heap = StringHeapBuilder()
    write_program_hex(program_hex, instructions)
    write_const_hex(const_hex, fn.__code__.co_consts, string_heap)
    write_string_hex(string_hex, string_heap)
    write_types(types_path, var_tags, warnings)
    write_cache_map(cache_map)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="pycore/programs/fib_iterative.py")
    parser.add_argument("--function", default="managed_entry")
    parser.add_argument("--program-hex", default="pycore/programs/program.hex")
    parser.add_argument("--const-hex", default="pycore/programs/consts.hex")
    parser.add_argument("--string-hex", default="pycore/programs/string_mem.hex")
    parser.add_argument("--types", default="pycore/programs/program.types")
    parser.add_argument("--cache-map", default="pycore/programs/cache_map.hex")
    args = parser.parse_args()
    preprocess(
        source=pathlib.Path(args.source),
        function_name=args.function,
        program_hex=pathlib.Path(args.program_hex),
        const_hex=pathlib.Path(args.const_hex),
        string_hex=pathlib.Path(args.string_hex),
        types_path=pathlib.Path(args.types),
        cache_map=pathlib.Path(args.cache_map),
    )


if __name__ == "__main__":
    main()
