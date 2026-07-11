#!/usr/bin/env python3
"""Preprocess CPython 3.14 bytecode for the PyCore hardware prototype."""

from __future__ import annotations

import argparse
import dis
import importlib.util
import pathlib
import struct
import sys
from dataclasses import dataclass, field
from types import FunctionType, SimpleNamespace
from typing import Any, Iterable


REQUIRED_PY = (3, 14)

TAG_UNINITIALIZED = 0b0000
TAG_INT           = 0b0001
TAG_FLOAT         = 0b0010
TAG_BOOL          = 0b0011
TAG_PTR           = 0b0100
TAG_TUPLE         = 0b0101
TAG_SHORT_STR     = 0b0110
TAG_LONG_STR      = 0b0111
TAG_OBJECT        = 0b1000
TAG_DICT          = 0b1001
TAG_LIST          = 0b1010
TAG_SET           = 0b1011
TAG_CODE_OBJECT   = 0b1100
TAG_FRAME_OBJECT  = 0b1101
TAG_UNUSED        = 0b1110
TAG_NONE          = 0b1111

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

# Python 3.14 introduced compound ("macro") instructions that fuse two
# consecutive LOAD_FAST / LOAD_FAST_BORROW opcodes into a single wordcode
# instruction.  The combined oparg packs both variable indices in 4 bits each:
#   combined_arg = (second_variable_index << 4) | first_variable_index
# where "first" is the instruction that executes first (pushed to stack first).
# Both variable indices must be < 16 for the pair to be emitted by the compiler.
_COMPOUND_EXPANSIONS: dict[str, tuple[str, str]] = {
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW": ("LOAD_FAST_BORROW", "LOAD_FAST_BORROW"),
    "LOAD_FAST_LOAD_FAST":               ("LOAD_FAST",        "LOAD_FAST"),
    "LOAD_FAST_BORROW_LOAD_FAST":        ("LOAD_FAST_BORROW", "LOAD_FAST"),
    "LOAD_FAST_LOAD_FAST_BORROW":        ("LOAD_FAST",        "LOAD_FAST_BORROW"),
}

# Jump instructions whose dis.Instruction.argval carries the absolute byte
# offset of the branch target.  These must have their arg pre-translated to
# filtered-instruction-index space before reaching remap_branch_args.
_BACKWARD_JUMP_OPS: frozenset[str] = frozenset({"JUMP_BACKWARD"})
_FORWARD_JUMP_OPS: frozenset[str] = frozenset({"JUMP_FORWARD"})
_ABSOLUTE_JUMP_OPS: frozenset[str] = frozenset({
    "POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE",
    "JUMP_IF_TRUE_OR_POP", "JUMP_IF_FALSE_OR_POP",
})
_ALL_JUMP_OPS: frozenset[str] = (
    _BACKWARD_JUMP_OPS | _FORWARD_JUMP_OPS | _ABSOLUTE_JUMP_OPS
)

# Instructions that are consumed / discarded by iter_filtered_instructions
# and therefore do NOT contribute to the filtered instruction stream.
_SKIP_OPS: frozenset[str] = frozenset({
    "CACHE", "EXTENDED_ARG", "PUSH_NULL", "LOAD_GLOBAL",
})


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


def load_function(source: pathlib.Path, function_name: str) -> Any:
    spec = importlib.util.spec_from_file_location("_pycore_input", source)
    if spec is None or spec.loader is None:
        raise ValueError(f"Unable to import {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fn = getattr(module, function_name, None)
    if not callable(fn):
        raise ValueError(f"Function '{function_name}' not found in {source}")
    return fn


def load_all_functions(
    source: pathlib.Path, entry_name: str
) -> list[tuple[str, Any]]:
    """
    Load every module-level Python function from *source*.

    The entry function (*entry_name*, always ``managed_entry``) is placed
    first so the preprocessor puts it at instruction-memory slot 0.  All
    other functions follow in source-definition order (ascending first-line
    number).  This ordering must be stable so that the two-pass slot-address
    computation and the final code-generation pass agree.
    """
    spec = importlib.util.spec_from_file_location("_pycore_input", source)
    if spec is None or spec.loader is None:
        raise ValueError(f"Unable to import {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    all_fns = [
        (name, obj)
        for name, obj in vars(module).items()
        if isinstance(obj, FunctionType)
    ]

    entry = [(n, f) for n, f in all_fns if n == entry_name]
    others = [(n, f) for n, f in all_fns if n != entry_name]

    if not entry:
        raise ValueError(f"Function '{entry_name}' not found in {source}")

    others.sort(key=lambda x: x[1].__code__.co_firstlineno)
    return entry + others


def _build_offset_to_filtered_idx(fn: Any) -> dict[int, int]:
    """
    Pre-scan *fn*'s bytecode and return a mapping
    ``original_byte_offset → filtered_instruction_index``.

    The filtered stream is what ``iter_filtered_instructions`` will ultimately
    yield: CACHE / EXTENDED_ARG / PUSH_NULL / LOAD_GLOBAL are absent; compound
    pair instructions (one bytecode word) contribute two entries.

    This map lets ``iter_filtered_instructions`` translate each jump
    instruction's ``argval`` (an absolute byte offset in the *original*
    bytecode) into the corresponding index in the *filtered* stream.  Without
    this translation, skipped CACHE words and compound-instruction expansions
    would corrupt every jump arg, causing KeyErrors or silent misbehaviour in
    ``remap_branch_args``.
    """
    idx = 0
    offset_map: dict[int, int] = {}
    for ins in dis.get_instructions(fn, show_caches=True):
        if ins.opname in _SKIP_OPS:
            continue
        offset_map[ins.offset] = idx
        if ins.opname in _COMPOUND_EXPANSIONS:
            # Both synthetic component instructions will be emitted; reserve
            # the second slot's (offset+2) entry too.
            offset_map[ins.offset + 2] = idx + 1
            idx += 2
        else:
            idx += 1
    return offset_map


def iter_filtered_instructions(
    fn: Any,
    callee_slots: dict[str, int],
) -> Iterable[Any]:
    """
    Yield hardware instruction objects for *fn*'s bytecode.

    Jump-arg pre-translation
    ~~~~~~~~~~~~~~~~~~~~~~~~
    Python 3.14 encodes all jump operands as word counts measured against the
    *original* bytecode (including CACHE slots and non-expanded compounds).
    Because we skip CACHE words and expand compound instructions, our filtered
    stream's instruction indices diverge from the original word count.

    To compensate, a pre-scan builds ``offset_to_filtered`` — a map from each
    instruction's *original* byte offset to its *filtered* index — before the
    main iteration begins.  Every jump instruction's ``argval`` (the absolute
    byte offset of its target, as resolved by ``dis``) is then looked up in
    this map, and the arg is replaced with a value expressed in
    filtered-instruction-index units.  ``remap_branch_args`` then converts
    those filtered-index counts to slot counts, which is its only job.

    Multi-function call-sequence transformation
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    * ``PUSH_NULL`` — discarded (no hardware equivalent).
    * ``LOAD_GLOBAL name`` — consumed; *name* is remembered as the pending
      callee.  The function must be present in *callee_slots*.
    * ``CALL argc`` — emitted as ``CALL (argc << 16) | callee_slot``.

    Python 3.14 compound pair instructions
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Fused ``LOAD_FAST_BORROW_LOAD_FAST_BORROW`` (and similar) are expanded
    back into their two component ``LOAD_FAST_BORROW`` / ``LOAD_FAST``
    instructions.
    """
    varnames = fn.__code__.co_varnames
    pending_callee: str | None = None

    # Build offset → filtered-index map once, before the main pass.
    offset_to_filtered = _build_offset_to_filtered_idx(fn)

    filtered_idx = 0

    for ins in dis.get_instructions(fn, show_caches=True):
        if ins.opname == "CACHE":
            continue
        if ins.opname == "EXTENDED_ARG":
            # CPython's disassembler has already folded the prefix into the
            # following Instruction.arg; the fetch stage also supports raw
            # EXTENDED_ARG for hand-written streams.
            continue

        # ── Expand Python 3.14+ compound (pair) instructions ──────────────
        if ins.opname in _COMPOUND_EXPANSIONS:
            op1_name, op2_name = _COMPOUND_EXPANSIONS[ins.opname]
            combined = ins.arg or 0

            # Prefer argval (tuple of variable names) when available to avoid
            # depending on the exact bit-packing convention used by CPython 3.14.
            argval = getattr(ins, "argval", None)
            if isinstance(argval, (tuple, list)) and len(argval) >= 2:
                try:
                    a1 = list(varnames).index(argval[0])
                    a2 = list(varnames).index(argval[1])
                except (ValueError, TypeError):
                    a1 = combined & 0xF
                    a2 = (combined >> 4) & 0xF
            else:
                # CPython 3.14 pair encoding: first variable index in low 4 bits.
                a1 = combined & 0xF
                a2 = (combined >> 4) & 0xF

            yield SimpleNamespace(
                opcode=dis.opmap[op1_name], opname=op1_name,
                arg=a1, offset=ins.offset,
            )
            yield SimpleNamespace(
                opcode=dis.opmap[op2_name], opname=op2_name,
                arg=a2, offset=ins.offset + 2,
            )
            filtered_idx += 2
            continue

        # ── Calling-convention instructions ────────────────────────────────

        if ins.opname == "PUSH_NULL":
            continue

        if ins.opname == "LOAD_GLOBAL":
            name = getattr(ins, "argval", None)
            if not isinstance(name, str):
                raise ValueError(
                    f"LOAD_GLOBAL with non-string argval {name!r} "
                    f"at bytecode offset {ins.offset}"
                )
            if name not in callee_slots:
                raise ValueError(
                    f"LOAD_GLOBAL '{name}' at bytecode offset {ins.offset}: "
                    f"not a function defined in this source file. "
                    f"Known functions: {sorted(callee_slots)}"
                )
            pending_callee = name
            continue

        if ins.opname == "CALL":
            if pending_callee is None:
                raise ValueError(
                    f"CALL at bytecode offset {ins.offset} without "
                    f"a preceding LOAD_GLOBAL"
                )
            argc = ins.arg or 0
            hw_arg = (argc << 16) | callee_slots[pending_callee]
            pending_callee = None
            yield SimpleNamespace(
                opcode=dis.opmap["CALL"],
                opname="CALL",
                arg=hw_arg,
                offset=ins.offset,
            )
            filtered_idx += 1
            continue

        # ── Jump instructions: pre-translate arg to filtered-index space ──
        # Python's jump args are word counts measured against the *original*
        # bytecode (including CACHE slots).  We replace them with counts /
        # indices in the *filtered* stream so that remap_branch_args can
        # convert correctly to slot units without needing to know about
        # skipped words or compound expansions.
        if ins.opname in _ALL_JUMP_OPS:
            target_byte = getattr(ins, "argval", None)
            if isinstance(target_byte, int):
                target_fidx = offset_to_filtered.get(target_byte)
                if target_fidx is None:
                    raise ValueError(
                        f"{ins.opname} at bytecode offset {ins.offset}: "
                        f"branch target byte offset {target_byte} not found "
                        f"in filtered instruction stream"
                    )
                if ins.opname in _BACKWARD_JUMP_OPS:
                    # remap_branch_args expects: arg = steps backward from i
                    new_arg = filtered_idx - target_fidx
                elif ins.opname in _FORWARD_JUMP_OPS:
                    # remap_branch_args expects: arg = steps forward from i
                    new_arg = target_fidx - filtered_idx
                else:
                    # Absolute jumps: remap_branch_args expects absolute index
                    new_arg = target_fidx
            else:
                new_arg = ins.arg or 0  # fallback: no argval available
            yield SimpleNamespace(
                opcode=ins.opcode, opname=ins.opname,
                arg=new_arg, offset=ins.offset,
            )
            filtered_idx += 1
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
        filtered_idx += 1


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
    for ins in instructions:
        arg = ins.arg or 0
        if not 0 <= arg < (1 << 32):
            raise ValueError(f"Instruction argument exceeds 32 bits: {ins}")

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


# Architectural value is now a 128-bit field carrying a 4-bit tag, i.e. a
# 132-bit entry. INT keeps a 64-bit signed fast path sign-extended into the
# upper 64 bits; FLOAT/BOOL live in the low 64 bits with the rest zero.
VAL_WIDTH = 128
VAL_MASK = (1 << VAL_WIDTH) - 1
TAG_WIDTH = 4
ENTRY_HEX_DIGITS = (TAG_WIDTH + VAL_WIDTH + 3) // 4  # ceil(132/4) == 33

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
    entry = ((tag & 0xF) << VAL_WIDTH) | (value & VAL_MASK)
    return f"{entry:0{ENTRY_HEX_DIGITS}x}"


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
            lines.append(
                f"{((ins.arg & 0xffffffff) << 8) | ins.opcode:0{IMEM_SLOT_HEX_DIGITS}x}"
            )
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
            # Hardware CALL arg = (argc << 16) | callee_slot; argc is in
            # the upper 16 bits.  For argc=0 the upper bits are 0, so the
            # right-shift still gives 0 regardless of the slot address.
            argc = (ins.arg or 0) >> 16
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


def _adjust_absolute_jumps(
    instructions: list[EmittedInstruction],
    slot_offset: int,
) -> list[EmittedInstruction]:
    """
    Add *slot_offset* to every absolute branch-target argument.

    ``remap_branch_args`` converts intra-function branch targets to slot
    indices relative to the function's own slot 0.  When multiple functions
    are laid out sequentially in instruction memory the absolute targets
    (``POP_JUMP_IF_*``, ``JUMP_IF_*_OR_POP``) must be shifted by the
    function's starting slot address to become program-absolute.

    Relative jumps (``JUMP_FORWARD`` / ``JUMP_BACKWARD``) are unaffected.
    """
    if slot_offset == 0:
        return instructions
    result: list[EmittedInstruction] = []
    for ins in instructions:
        if ins.opname in (
            "POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE",
            "JUMP_IF_TRUE_OR_POP", "JUMP_IF_FALSE_OR_POP",
        ):
            ins = EmittedInstruction(
                opcode=ins.opcode,
                arg=ins.arg + slot_offset,
                source_offset=ins.source_offset,
                opname=ins.opname,
                const_tag=ins.const_tag,
                const_value=ins.const_value,
            )
        result.append(ins)
    return result


def _count_slots(instructions: Iterable[EmittedInstruction]) -> int:
    """Return the total instruction-memory slots occupied by *instructions*."""
    return sum(3 if ins.opname == "LOAD_CONST" else 1 for ins in instructions)


def preprocess(
    source: pathlib.Path,
    function_name: str,
    program_hex: pathlib.Path,
    string_hex: pathlib.Path,
    types_path: pathlib.Path,
    cache_map: pathlib.Path,
) -> None:
    """
    Compile *function_name* (and all other module-level functions) from
    *source* into PyCore instruction-memory and string-memory images.

    Multi-function programs are supported via a two-pass strategy:

    Pass 1 — compute each function's slot address by doing a dry run
    (callee addresses temporarily set to 0 just to determine instruction
    count; slot count is invariant under the callee value).

    Pass 2 — compile each function for real using the resolved callee_slots,
    remap intra-function branch targets, and shift absolute jump targets by
    the function's starting slot offset.
    """
    require_python_3_14()

    all_fns = load_all_functions(source, function_name)

    # ── Pass 1: dry-run each function to compute slot counts / addresses ──
    # CALL's slot count (1) is independent of its argument value, so
    # callee_slots=0 placeholders give the same counts as real values.
    dummy_slots: dict[str, int] = {fname: 0 for fname, _ in all_fns}
    fn_slot_counts: dict[str, int] = {}
    for fname, fn in all_fns:
        dry = list(emit_instruction_words(
            iter_filtered_instructions(fn, dummy_slots),
            co_consts=fn.__code__.co_consts,
            string_heap=StringHeapBuilder(),
        ))
        fn_slot_counts[fname] = _count_slots(dry)

    # Build the definitive callee_slots map.
    callee_slots: dict[str, int] = {}
    cur = 0
    for fname, _ in all_fns:
        callee_slots[fname] = cur
        cur += fn_slot_counts[fname]

    # ── Pass 2: compile each function with resolved callee addresses ──────
    string_heap = StringHeapBuilder()
    all_instructions: list[EmittedInstruction] = []

    for fname, fn in all_fns:
        fn_start_slot = callee_slots[fname]
        instrs = list(emit_instruction_words(
            iter_filtered_instructions(fn, callee_slots),
            co_consts=fn.__code__.co_consts,
            string_heap=string_heap,
        ))
        remapped = remap_branch_args(instrs)
        adjusted = _adjust_absolute_jumps(remapped, fn_start_slot)
        all_instructions.extend(adjusted)

    # Type inference operates on the entry function only.
    entry_fn = all_fns[0][1]
    entry_instrs_typed = list(emit_instruction_words(
        iter_filtered_instructions(entry_fn, callee_slots),
        co_consts=entry_fn.__code__.co_consts,
        string_heap=StringHeapBuilder(),
    ))
    var_tags, warnings = infer_types(entry_fn, entry_instrs_typed)

    write_program_hex(program_hex, all_instructions)
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
