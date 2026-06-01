#!/usr/bin/env python3
"""Preprocess CPython 3.14 bytecode into PyCore images.

The emitted program stream uses PyCore's internal canonical opcode numbering so
RTL decode stays stable even if CPython renumbers opcodes in future releases.
"""

from __future__ import annotations

import argparse
import dis
import pathlib
import runpy
import sys
from dataclasses import dataclass


REQUIRED_PY = (3, 14)

TAG_UNINIT = 0
TAG_INT = 1
TAG_BOOL = 2
TAG_REF = 3

RAW_SUPPORTED_OPS = {
    "RESUME",
    "NOP",
    "LOAD_CONST",
    "LOAD_SMALL_INT",
    "LOAD_FAST",
    "LOAD_FAST_BORROW",
    "LOAD_FAST_LOAD_FAST",
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
    "STORE_FAST",
    "POP_TOP",
    "COPY",
    "SWAP",
    "BINARY_OP",
    "COMPARE_OP",
    "UNARY_NOT",
    "UNARY_NEGATIVE",
    "UNARY_POSITIVE",
    "UNARY_INVERT",
    "JUMP_FORWARD",
    "JUMP_BACKWARD",
    "JUMP_BACKWARD_NO_INTERRUPT",
    "POP_JUMP_FORWARD_IF_TRUE",
    "POP_JUMP_FORWARD_IF_FALSE",
    "POP_JUMP_BACKWARD_IF_TRUE",
    "POP_JUMP_BACKWARD_IF_FALSE",
    "POP_JUMP_IF_TRUE",
    "POP_JUMP_IF_FALSE",
    "JUMP_IF_TRUE_OR_POP",
    "JUMP_IF_FALSE_OR_POP",
    "CALL",
    "RETURN_VALUE",
    "EXTENDED_ARG",
}

OPNAME_ALIAS = {
    "LOAD_FAST_BORROW": "LOAD_FAST",
    "POP_JUMP_IF_TRUE": "POP_JUMP_FORWARD_IF_TRUE",
    "POP_JUMP_IF_FALSE": "POP_JUMP_FORWARD_IF_FALSE",
    "JUMP_BACKWARD_NO_INTERRUPT": "JUMP_BACKWARD",
}

OPCODE_ENCODING = {
    "POP_TOP": 1,
    "NOP": 9,
    "UNARY_POSITIVE": 10,
    "UNARY_NEGATIVE": 11,
    "UNARY_NOT": 12,
    "UNARY_INVERT": 15,
    "RETURN_VALUE": 83,
    "SWAP": 99,
    "LOAD_SMALL_INT": 94,
    "LOAD_CONST": 100,
    "COMPARE_OP": 107,
    "JUMP_FORWARD": 110,
    "JUMP_IF_FALSE_OR_POP": 111,
    "JUMP_IF_TRUE_OR_POP": 112,
    "POP_JUMP_FORWARD_IF_FALSE": 114,
    "POP_JUMP_FORWARD_IF_TRUE": 115,
    "POP_JUMP_BACKWARD_IF_FALSE": 116,
    "POP_JUMP_BACKWARD_IF_TRUE": 117,
    "COPY": 120,
    "BINARY_OP": 122,
    "LOAD_FAST": 124,
    "STORE_FAST": 125,
    "JUMP_BACKWARD": 140,
    "EXTENDED_ARG": 144,
    "RESUME": 151,
    "CALL": 171,
}

SUPPORTED_BINARY_ARGS = {
    0, 1, 2, 3, 5, 6, 7, 9, 10, 12,
    13, 14, 15, 16, 18, 19, 20, 22, 23, 25,
}

SUPPORTED_COMPARE_ARGS = {0, 1, 2, 3, 4, 5}


@dataclass
class FoldedInstruction:
    opname: str
    opcode: int
    arg: int
    offset: int


def _require_python_3_14() -> None:
    if sys.version_info[:2] != REQUIRED_PY:
        raise RuntimeError(
            f"tools/preprocess.py is pinned to Python {REQUIRED_PY[0]}.{REQUIRED_PY[1]} "
            f"(got {sys.version_info.major}.{sys.version_info.minor})"
        )


def _load_function(path: pathlib.Path, function_name: str):
    namespace = runpy.run_path(str(path))
    fn = namespace.get(function_name)
    if fn is None or not callable(fn):
        raise ValueError(f"Function '{function_name}' not found or not callable in {path}")
    return fn


def _canonicalize_opname(opname: str) -> str:
    return OPNAME_ALIAS.get(opname, opname)


def _emit_canonical(out: list[FoldedInstruction], opname: str, arg: int, offset: int) -> None:
    if opname not in OPCODE_ENCODING:
        raise ValueError(f"Opcode '{opname}' has no canonical encoding")
    out.append(FoldedInstruction(opname=opname, opcode=OPCODE_ENCODING[opname], arg=arg, offset=offset))


def _fold_extended_args(fn) -> list[FoldedInstruction]:
    out: list[FoldedInstruction] = []
    ext_accum = 0
    for ins in dis.get_instructions(fn):
        if ins.opname == "CACHE":
            continue

        if ins.opname not in RAW_SUPPORTED_OPS:
            raise ValueError(f"Unsupported opcode {ins.opname} at offset {ins.offset}")

        arg = 0 if ins.arg is None else int(ins.arg)
        if ins.opname == "EXTENDED_ARG":
            ext_accum = (ext_accum << 8) | (arg & 0xFF)
            continue

        if ext_accum:
            arg = (ext_accum << 8) | arg
            ext_accum = 0

        canonical = _canonicalize_opname(ins.opname)

        if canonical == "LOAD_FAST_LOAD_FAST":
            hi = (arg >> 4) & 0xF
            lo = arg & 0xF
            _emit_canonical(out, "LOAD_FAST", hi, ins.offset)
            _emit_canonical(out, "LOAD_FAST", lo, ins.offset)
            continue

        if canonical == "LOAD_FAST_BORROW_LOAD_FAST_BORROW":
            hi = (arg >> 4) & 0xF
            lo = arg & 0xF
            _emit_canonical(out, "LOAD_FAST", hi, ins.offset)
            _emit_canonical(out, "LOAD_FAST", lo, ins.offset)
            continue

        if canonical == "BINARY_OP" and arg not in SUPPORTED_BINARY_ARGS:
            raise ValueError(f"Unsupported BINARY_OP arg {arg} at offset {ins.offset}")
        if canonical == "COMPARE_OP" and arg not in SUPPORTED_COMPARE_ARGS:
            raise ValueError(f"Unsupported COMPARE_OP arg {arg} at offset {ins.offset}")

        _emit_canonical(out, canonical, arg, ins.offset)
    return out


def _tag_const(value: object) -> tuple[int, int]:
    if isinstance(value, bool):
        return TAG_BOOL, 1 if value else 0
    if isinstance(value, int):
        return TAG_INT, value & ((1 << 64) - 1)
    if value is None:
        return TAG_UNINIT, 0
    return TAG_REF, 0


def _emit_program_hex(instructions: list[FoldedInstruction], out_path: pathlib.Path) -> None:
    lines: list[str] = []
    for ins in instructions:
        word = ((ins.arg & 0xFFFFFFFF) << 8) | (ins.opcode & 0xFF)
        lines.append(f"{word:010x}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _emit_const_hex(fn, out_path: pathlib.Path) -> None:
    lines: list[str] = []
    for c in fn.__code__.co_consts:
        tag, value = _tag_const(c)
        packed = ((tag & 0x3) << 64) | (value & ((1 << 64) - 1))
        lines.append(f"{packed:017x}")
    if not lines:
        lines = [f"{0:017x}"]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _infer_types(fn, instructions: list[FoldedInstruction]) -> dict[str, str]:
    varnames = fn.__code__.co_varnames
    stack: list[str] = []
    inferred: dict[str, str] = {}

    def pop_type(default: str = "UNKNOWN") -> str:
        return stack.pop() if stack else default

    for ins in instructions:
        if ins.opname == "LOAD_CONST":
            c = fn.__code__.co_consts[ins.arg] if ins.arg < len(fn.__code__.co_consts) else None
            if isinstance(c, bool):
                stack.append("BOOL")
            elif isinstance(c, int):
                stack.append("INT")
            else:
                stack.append("REF")
        elif ins.opname == "LOAD_SMALL_INT":
            stack.append("INT")
        elif ins.opname == "LOAD_FAST":
            name = varnames[ins.arg] if ins.arg < len(varnames) else f"var_{ins.arg}"
            stack.append(inferred.get(name, "UNKNOWN"))
        elif ins.opname == "STORE_FAST":
            name = varnames[ins.arg] if ins.arg < len(varnames) else f"var_{ins.arg}"
            inferred[name] = pop_type()
        elif ins.opname in {"UNARY_NEGATIVE", "UNARY_POSITIVE", "UNARY_INVERT"}:
            t = pop_type()
            stack.append("INT" if t in {"INT", "BOOL"} else "UNKNOWN")
        elif ins.opname == "UNARY_NOT":
            _ = pop_type()
            stack.append("BOOL")
        elif ins.opname == "BINARY_OP":
            rhs = pop_type()
            lhs = pop_type()
            if ins.arg in {1, 7} and lhs == "BOOL" and rhs == "BOOL":
                stack.append("BOOL")
            elif lhs in {"INT", "BOOL"} and rhs in {"INT", "BOOL"}:
                stack.append("INT")
            else:
                stack.append("UNKNOWN")
        elif ins.opname == "COMPARE_OP":
            _ = pop_type()
            _ = pop_type()
            stack.append("BOOL")
        elif ins.opname == "COPY":
            if stack:
                depth = ins.arg
                stack.append(stack[-1 - depth] if depth < len(stack) else "UNKNOWN")
        elif ins.opname == "SWAP":
            if stack and ins.arg < len(stack):
                i = -1
                j = -1 - ins.arg
                stack[i], stack[j] = stack[j], stack[i]
        elif ins.opname == "POP_TOP":
            _ = pop_type()
        elif ins.opname in {
            "POP_JUMP_FORWARD_IF_TRUE",
            "POP_JUMP_FORWARD_IF_FALSE",
            "POP_JUMP_BACKWARD_IF_TRUE",
            "POP_JUMP_BACKWARD_IF_FALSE",
            "RETURN_VALUE",
        }:
            _ = pop_type()

    return inferred


def _emit_types(path: pathlib.Path, inferred: dict[str, str]) -> None:
    lines = [f"{name}: {typ}" for name, typ in sorted(inferred.items())]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="ascii")


def main() -> None:
    _require_python_3_14()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="programs/bool_kernel.py")
    parser.add_argument("--function", default="managed_entry")
    parser.add_argument("--program-hex", default="programs/pycore_prog.hex")
    parser.add_argument("--const-hex", default="programs/pycore_consts.hex")
    parser.add_argument("--types-out", default="programs/pycore.types")
    args = parser.parse_args()

    source = pathlib.Path(args.source)
    fn = _load_function(source, args.function)
    insns = _fold_extended_args(fn)
    inferred = _infer_types(fn, insns)

    _emit_program_hex(insns, pathlib.Path(args.program_hex))
    _emit_const_hex(fn, pathlib.Path(args.const_hex))
    _emit_types(pathlib.Path(args.types_out), inferred)

    for c in fn.__code__.co_consts:
        if isinstance(c, int) and not (-(1 << 63) <= c <= (1 << 63) - 1):
            print(f"WARNING: constant {c} exceeds signed 64-bit range and will wrap")


if __name__ == "__main__":
    main()
