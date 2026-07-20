#!/usr/bin/env python3
"""Deprecated legacy single-function preprocessor for PyCore.

The primary CPython image-boot path is image_from_source.py.  This module is
kept for older container/type fixtures that still use inline LOAD_CONST payloads
and branch remapping.
"""

from __future__ import annotations

import argparse
import dis
import importlib.util
import opcode as _opcode_module
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Iterable

from encoding import (
    ENTRY_HEX_DIGITS,
    IMEM_SLOT_HEX_DIGITS,
    SHORT_STR_DATA_SHIFT,
    SHORT_STR_MAX_BYTES,
    SHORT_STR_SIZE_SHIFT,
    STRING_MEM_BYTES,
    STRING_RUNTIME_BASE,
    TAG_BOOL,
    TAG_CODE_OBJECT,
    TAG_DICT,
    TAG_FLOAT,
    TAG_FRAME_OBJECT,
    TAG_INT,
    TAG_LIST,
    TAG_LONG_STR,
    TAG_NONE,
    TAG_NULL,
    TAG_OBJECT,
    TAG_PTR,
    TAG_SET,
    TAG_SHORT_STR,
    TAG_TUPLE,
    TAG_UNINIT,
    TAG_UNINITIALIZED,
    TAG_UNUSED,
    VAL_MASK,
    VAL_WIDTH,
    StringHeapBuilder,
    float_bits,
    format_entry,
    format_imem_slot,
    tag_constant,
)


REQUIRED_PY = (3, 14)

# ---------------------------------------------------------------------------
# Opcode numbers and subop values resolved from the running Python 3.14
# interpreter.  Do NOT hand-transcribe these from memory or training data.
# The block below runs at import time and will raise AttributeError / KeyError
# if the interpreter does not expose the expected attributes, which catches
# forward-compatibility breaks early.
#
# Verified values (Python 3.14.x):
#   OP_BUILD_LIST                       = 46
#   OP_BUILD_MAP                        = 47
#   OP_BUILD_TUPLE                      = 51
#   OP_STORE_SUBSCR                     = 38
#   OP_BINARY_OP                        = 44
#   OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW = 87
#   NBARG_SUBSCR                        = 26
# ---------------------------------------------------------------------------
_OM = _opcode_module.opmap
OP_BUILD_LIST    = _OM["BUILD_LIST"]
OP_BUILD_MAP     = _OM["BUILD_MAP"]
OP_BUILD_TUPLE   = _OM["BUILD_TUPLE"]
OP_STORE_SUBSCR  = _OM["STORE_SUBSCR"]
OP_BINARY_OP     = _OM["BINARY_OP"]
OP_LOAD_FAST_BORROW_LOAD_FAST_BORROW = _OM.get(
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW", None
)
OP_LIST_APPEND   = _OM["LIST_APPEND"]
OP_LIST_EXTEND   = _OM["LIST_EXTEND"]

# NB_SUBSCR oparg: locate "NB_SUBSCR" in _nb_ops by searching for the entry
# whose first element contains "SUBSCR".
_nb_ops = getattr(_opcode_module, "_nb_ops", [])
NBARG_SUBSCR: int | None = None
for _i, _entry in enumerate(_nb_ops):
    if "SUBSCR" in str(_entry[0]).upper():
        NBARG_SUBSCR = _i
        break
if NBARG_SUBSCR is None:
    raise RuntimeError(
        "Could not resolve NB_SUBSCR oparg from opcode._nb_ops. "
        "Verify Python version is 3.14."
    )

# Opcodes that have been intentionally deferred (not yet implemented).
# Preprocess raises a specific error when it encounters any of these so the
# user knows to use a supported alternative.
DEFERRED_OPS: dict[str, str] = {
    "MAP_ADD":       "dict mutation not yet implemented",
    "DICT_UPDATE":   "dict.update not yet implemented",
    "DICT_MERGE":    "dict merge not yet implemented",
    "DELETE_SUBSCR": "del x[k] not yet implemented",
    "CONTAINS_OP":   "in / not-in operator not yet implemented",
    "BINARY_SLICE":  "slice notation not yet implemented",
    "STORE_SLICE":   "slice assignment not yet implemented",
    "BUILD_SET":     "set literals not yet implemented",
    "SET_ADD":       "set.add not yet implemented",
    "SET_UPDATE":    "set.update not yet implemented",
    "LOAD_GLOBAL":   "module/global lookup is supported by image_from_source.py",
    "LOAD_NAME":     "module/name lookup is supported by image_from_source.py",
    "STORE_NAME":    "module/name stores are supported by image_from_source.py",
    "STORE_GLOBAL":  "global stores are supported by image_from_source.py",
    "PUSH_NULL":     "CALL self-or-null layout is supported by image_from_source.py",
    "MAKE_FUNCTION": "function objects are supported by image_from_source.py",
}

SUPPORTED_OPS = {
    "RESUME",
    "CACHE",
    "EXTENDED_ARG",
    "LOAD_FAST",
    "LOAD_FAST_BORROW",
    # LOAD_FAST_BORROW_LOAD_FAST_BORROW (opcode 87, Python 3.14): loads two
    # locals in one instruction.  Expanded to two LOAD_FAST_BORROW in
    # emit_instruction_words so hardware never sees this combined opcode.
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
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
    # Container operations (in-scope for PyCore dict-list support).
    "BUILD_LIST",
    "BUILD_MAP",
    "BUILD_TUPLE",
    "STORE_SUBSCR",
    # LIST_APPEND / LIST_EXTEND fast-path / grow-trap: see CONT_LIST_APPEND
    # and CONT_LIST_EXTEND (pycore_core.sv). Comprehensions still fail
    # validation on FOR_ITER/GET_ITER (deferred); LIST_EXTEND is also
    # emitted by list-display unpack (`[a, *b]` / `[*a, *b]`).
    "LIST_APPEND",
    "LIST_EXTEND",
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
    # NB_SUBSCR (oparg 26): subscript read x[k] — routes to S_CONTAINER FSM.
    NBARG_SUBSCR,
}


@dataclass(frozen=True)
class EmittedInstruction:
    opcode: int
    arg: int
    source_offset: int
    opname: str
    # For LOAD_CONST only: the pre-encoded 4-bit tag and 128-bit value that will
    # be embedded inline in the instruction stream.  None for all other opcodes.
    const_tag: int | None = None
    const_value: int | None = None


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
        if ins.opname in DEFERRED_OPS:
            reason = DEFERRED_OPS[ins.opname]
            raise ValueError(
                f"Deferred opcode {ins.opname!r} at bytecode offset {ins.offset}: "
                f"{reason}.  Use a different construct or wait for a future PyCore "
                f"release that supports this operation."
            )
        if ins.opname not in SUPPORTED_OPS:
            raise ValueError(
                f"Unsupported opcode {ins.opname!r} at bytecode offset {ins.offset}"
            )
        if ins.opname == "BINARY_OP" and (ins.arg or 0) not in SUPPORTED_BINARY_ARGS:
            raise ValueError(
                f"Unsupported BINARY_OP oparg {ins.arg} at bytecode offset {ins.offset}"
            )
        yield ins


def emit_instruction_words(
    instructions: Iterable[dis.Instruction],
    co_consts: tuple[object, ...] | None = None,
    string_heap: "StringHeapBuilder | None" = None,
) -> list[EmittedInstruction]:
    """Convert filtered dis.Instruction objects to EmittedInstruction records.

    For LOAD_CONST instructions the constant value is eagerly encoded using
    tag_constant so that write_program_hex can embed it inline in the
    instruction stream.  co_consts and string_heap must be provided when
    LOAD_CONST instructions are present.
    """
    emitted: list[EmittedInstruction] = []
    lfb_opcode = _OM.get("LOAD_FAST_BORROW", 86)
    for ins in instructions:
        arg = ins.arg or 0
        if not 0 <= arg < (1 << 32):
            raise ValueError(f"Instruction argument exceeds 32 bits: {ins}")

        # Expand LOAD_FAST_BORROW_LOAD_FAST_BORROW → two LOAD_FAST_BORROW.
        # Encoding: arg[7:4] = first variable index, arg[3:0] = second.
        # This keeps the hardware simple: it only ever sees LOAD_FAST_BORROW.
        if ins.opname == "LOAD_FAST_BORROW_LOAD_FAST_BORROW":
            first_idx  = arg >> 4
            second_idx = arg & 0xF
            for var_idx in (first_idx, second_idx):
                emitted.append(EmittedInstruction(
                    opcode=lfb_opcode,
                    arg=var_idx,
                    source_offset=ins.offset,
                    opname="LOAD_FAST_BORROW",
                ))
            continue

        const_tag = None
        const_value = None
        if ins.opname == "LOAD_CONST":
            if co_consts is None or string_heap is None:
                raise ValueError(
                    "co_consts and string_heap are required when LOAD_CONST "
                    "instructions are present"
                )
            const_obj = co_consts[arg]
            const_tag, const_value = tag_constant(const_obj, string_heap)

        emitted.append(
            EmittedInstruction(
                opcode=ins.opcode,
                arg=arg,
                source_offset=ins.offset,
                opname=ins.opname,
                const_tag=const_tag,
                const_value=const_value,
            )
        )
    return emitted


def write_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="ascii")


def compute_slot_map(instructions: list[EmittedInstruction]) -> dict[int, int]:
    """Map each instruction index to its starting imem slot index.

    LOAD_CONST instructions occupy 3 consecutive slots (one header word plus
    two value words); every other instruction occupies exactly 1 slot.  The
    returned dict also includes an entry at index len(instructions) that gives
    the slot address one past the last instruction.
    """
    slot_map: dict[int, int] = {}
    slot = 0
    for i, ins in enumerate(instructions):
        slot_map[i] = slot
        slot += 3 if ins.opname == "LOAD_CONST" else 1
    slot_map[len(instructions)] = slot
    return slot_map


def remap_branch_args(instructions: list[EmittedInstruction]) -> list[EmittedInstruction]:
    """Rewrite jump arguments from instruction-index units to slot-index units.

    The hardware branch unit operates on slot addresses, so any jump argument
    that was expressed as an instruction count must be converted to the
    equivalent slot offset or slot address now that LOAD_CONST instructions are
    3 slots wide instead of 1.

    Semantics matched to the pycore_branch.sv implementation:
      JUMP_FORWARD  arg=N  ->  branch_target = pc + N  (relative, N slots forward)
      JUMP_BACKWARD arg=N  ->  branch_target = pc - N  (relative, N slots back)
      POP_JUMP_IF_TRUE/FALSE arg=N  ->  branch_target = N  (absolute slot address)

    With 1:1 instruction-to-slot mapping these pass through unchanged.  When
    LOAD_CONST instructions are present the offsets grow to account for the
    extra slots they occupy.
    """
    slot_map = compute_slot_map(instructions)
    remapped: list[EmittedInstruction] = []

    for i, ins in enumerate(instructions):
        arg = ins.arg
        if ins.opname == "JUMP_FORWARD":
            # Relative: target is arg instruction-indices ahead of instruction i.
            # In slot space: slot_map[i + arg] - slot_map[i].
            target_idx = i + arg
            new_arg = slot_map[target_idx] - slot_map[i]
        elif ins.opname == "JUMP_BACKWARD":
            # Relative: target is arg instruction-indices behind instruction i.
            target_idx = i - arg
            new_arg = slot_map[i] - slot_map[target_idx]
        elif ins.opname in ("POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE",
                            "JUMP_IF_TRUE_OR_POP", "JUMP_IF_FALSE_OR_POP"):
            # Absolute: arg is the target instruction index; convert to slot.
            new_arg = slot_map[arg]
        else:
            new_arg = arg

        if new_arg != arg:
            ins = EmittedInstruction(
                opcode=ins.opcode,
                arg=new_arg,
                source_offset=ins.source_offset,
                opname=ins.opname,
                const_tag=ins.const_tag,
                const_value=ins.const_value,
            )
        remapped.append(ins)

    return remapped


def write_program_hex(path: pathlib.Path, instructions: Iterable[EmittedInstruction]) -> None:
    """Write the instruction memory image.

    LOAD_CONST instructions expand to three 64-bit slots:
      Slot 0  bits[63:60] = tag[3:0],  bits[7:0] = opcode
      Slot 1  value[127:64]
      Slot 2  value[63:0]

    All other instructions remain a single 64-bit slot:
      bits[39:8] = arg[31:0],  bits[7:0] = opcode
    """
    lines: list[str] = []
    for ins in instructions:
        if ins.opname == "LOAD_CONST":
            assert ins.const_tag is not None and ins.const_value is not None
            tag = ins.const_tag
            val = ins.const_value
            # Slot 0: tag in the four MSBs, opcode in the eight LSBs.
            word0 = ((tag & 0xF) << 60) | ins.opcode
            # Slot 1: value[127:64]
            word1 = (val >> 64) & 0xFFFF_FFFF_FFFF_FFFF
            # Slot 2: value[63:0]
            word2 = val & 0xFFFF_FFFF_FFFF_FFFF
            lines.append(f"{word0:0{IMEM_SLOT_HEX_DIGITS}x}")
            lines.append(f"{word1:0{IMEM_SLOT_HEX_DIGITS}x}")
            lines.append(f"{word2:0{IMEM_SLOT_HEX_DIGITS}x}")
        else:
            lines.append(format_imem_slot(ins.opcode, ins.arg))
    write_text(path, "\n".join(lines) + ("\n" if lines else ""))


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
    if isinstance(entries, dict):
        return [int(entries.get(i, 0)) for i in range(256)]
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
    """Infer the tag of each local variable from the instruction stream.

    Must be called on the original (pre-remapping) instruction list so that
    LOAD_CONST entries still carry const_tag (set by emit_instruction_words).
    """
    local_names = list(fn.__code__.co_varnames)
    var_tags = {name: TAG_UNINITIALIZED for name in local_names}
    stack: list[int] = []
    warnings: list[str] = []

    for ins in instructions:
        if ins.opname == "LOAD_CONST":
            # Use the pre-encoded tag stored in the EmittedInstruction.
            tag = ins.const_tag if ins.const_tag is not None else TAG_OBJECT
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
        elif ins.opname == "BUILD_LIST":
            count = ins.arg or 0
            for _ in range(min(count, len(stack))):
                stack.pop()
            stack.append(TAG_LIST)
        elif ins.opname == "BUILD_TUPLE":
            count = ins.arg or 0
            for _ in range(min(count, len(stack))):
                stack.pop()
            stack.append(TAG_TUPLE)
        elif ins.opname == "BUILD_MAP":
            count = ins.arg or 0
            for _ in range(min(2 * count, len(stack))):
                stack.pop()
            stack.append(TAG_DICT)
        elif ins.opname == "STORE_SUBSCR":
            # Pops key, container, value (3 items); pushes nothing.
            for _ in range(min(3, len(stack))):
                stack.pop()
        elif ins.opname == "LIST_APPEND":
            # Pops only the appended element (TOS); the list handle,
            # `oparg - 1` slots further down, is left in place untouched.
            if stack:
                stack.pop()
        elif ins.opname == "LIST_EXTEND":
            # Same stack shape as LIST_APPEND: pop only the iterable (TOS);
            # the list handle at RF[tos-1-arg] stays.
            if stack:
                stack.pop()
        elif ins.opname == "BINARY_OP":
            rhs = stack.pop() if stack else TAG_OBJECT
            lhs = stack.pop() if stack else TAG_OBJECT
            if ins.arg == NBARG_SUBSCR:
                # Subscript read: result type is unknown (element type not tracked).
                result_tag = TAG_OBJECT
                if lhs not in (TAG_LIST, TAG_DICT, TAG_TUPLE, TAG_OBJECT):
                    warnings.append(
                        f"NB_SUBSCR on non-container tag {lhs} at offset {ins.source_offset}"
                    )
            else:
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
        TAG_INT: "INT",
        TAG_UNINITIALIZED: "UNINITIALIZED",
        TAG_FLOAT: "FLOAT",
        TAG_BOOL: "BOOL",
        TAG_PTR: "PTR",
        TAG_TUPLE: "TUPLE",
        TAG_SHORT_STR: "SHORT_STR",
        TAG_LONG_STR: "LONG_STR",
        TAG_OBJECT: "OBJECT",
        TAG_DICT: "DICT",
        TAG_LIST: "LIST",
        TAG_SET: "SET",
        TAG_CODE_OBJECT: "CODE_OBJECT",
        TAG_FRAME_OBJECT: "FRAME_OBJECT",
        TAG_UNUSED: "UNUSED",
        TAG_NONE: "NONE",
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
    string_hex: pathlib.Path,
    types_path: pathlib.Path,
    cache_map: pathlib.Path,
) -> None:
    require_python_3_14()
    fn = load_function(source, function_name)
    string_heap = StringHeapBuilder()
    instructions = emit_instruction_words(
        iter_filtered_instructions(fn),
        co_consts=fn.__code__.co_consts,
        string_heap=string_heap,
    )
    var_tags, warnings = infer_types(fn, instructions)
    instructions = remap_branch_args(instructions)
    write_program_hex(program_hex, instructions)
    write_string_hex(string_hex, string_heap)
    write_types(types_path, var_tags, warnings)
    write_cache_map(cache_map)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="pycore/programs/smoke_return.py")
    parser.add_argument("--function", default="managed_entry")
    parser.add_argument("--program-hex", default="pycore/programs/program.hex")
    parser.add_argument("--string-hex", default="pycore/programs/string_mem.hex")
    parser.add_argument("--types", default="pycore/programs/program.types")
    parser.add_argument("--cache-map", default="pycore/programs/cache_map.hex")
    args = parser.parse_args()
    preprocess(
        source=pathlib.Path(args.source),
        function_name=args.function,
        program_hex=pathlib.Path(args.program_hex),
        string_hex=pathlib.Path(args.string_hex),
        types_path=pathlib.Path(args.types),
        cache_map=pathlib.Path(args.cache_map),
    )


if __name__ == "__main__":
    main()
