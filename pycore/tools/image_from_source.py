#!/usr/bin/env python3.14
"""Build PyCore CPython module images from Python source.

This is the primary image-boot path.  It preserves CPython 3.14 wordcode
one-for-one: every raw two-byte ``co_code`` unit becomes one 64-bit imem slot.
"""

from __future__ import annotations

import argparse
import dis
import opcode as _opcode_module
import pathlib
import sys
import types
from dataclasses import dataclass, field
from typing import Iterable

from encoding import (
    BOOT_RECORD_ADDR,
    HEAP_BASE,
    STRING_MEM_BYTES,
    TAG_NONE,
    VAL_MASK,
    StringHeapBuilder,
    dict_slot_count_for_stores,
    format_imem_slot,
    tag_constant,
)
from heap_image import HeapImageBuilder, Tagged


REQUIRED_PY = (3, 14)

_OM = _opcode_module.opmap
OP_EXTENDED_ARG = _OM["EXTENDED_ARG"]
OP_CACHE = _OM["CACHE"]

_nb_ops = getattr(_opcode_module, "_nb_ops", [])
NBARG_SUBSCR: int | None = None
for _idx, _entry in enumerate(_nb_ops):
    if "SUBSCR" in str(_entry[0]).upper():
        NBARG_SUBSCR = _idx
        break
if NBARG_SUBSCR is None:
    raise RuntimeError("Could not resolve NB_SUBSCR oparg from opcode._nb_ops")

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
    NBARG_SUBSCR,
}

# CPython 3.14 packs the selector in bits 7:5, a force-bool flag in bit 4,
# and the quickened comparison mask in bits 3:0.  Accept only forms emitted
# by this pinned interpreter rather than silently admitting future encodings.
SUPPORTED_COMPARE_ARGS = {
    2, 18,      # <
    42, 58,     # <=
    72, 88,     # ==
    103, 119,   # !=
    132, 148,   # >
    172, 188,   # >=
}

SUPPORTED_OPS = {
    "RESUME",
    "CACHE",
    "EXTENDED_ARG",
    "LOAD_CONST",
    "STORE_FAST",
    "STORE_FAST_LOAD_FAST",
    "STORE_FAST_STORE_FAST",
    "DELETE_FAST",
    "LOAD_FAST_AND_CLEAR",
    "LOAD_FAST_CHECK",
    "LOAD_SMALL_INT",
    "POP_TOP",
    "END_FOR",
    "GET_ITER",
    "FOR_ITER",
    "POP_ITER",
    "NOP",
    "NOT_TAKEN",
    "TO_BOOL",
    "UNARY_NOT",
    "BINARY_OP",
    "COMPARE_OP",
    "IS_OP",
    "BUILD_LIST",
    "BUILD_MAP",
    "BUILD_TUPLE",
    "STORE_SUBSCR",
    "DELETE_SUBSCR",
    "CONTAINS_OP",
    "COPY",
    "SWAP",
    "CALL",
    "RETURN_VALUE",
    "LOAD_GLOBAL",
    "LOAD_NAME",
    "STORE_NAME",
    "STORE_GLOBAL",
    "PUSH_NULL",
    "MAKE_FUNCTION",
    # LIST_APPEND spare-capacity fast path / grow-trap, and LIST_EXTEND
    # (empty no-op / always-excore non-empty) are in CONT_LIST_APPEND /
    # CONT_LIST_EXTEND (pycore_core.sv). LIST_APPEND appears inside
    # comprehensions whose GET_ITER/FOR_ITER path is accepted for LIST/TUPLE
    # sources. LIST_EXTEND is emitted by list-display unpack forms such as
    # `[1, 2, *x]` and `[*a, *b]` — those are accepted here. Sources must be
    # LIST or TUPLE.
    "LIST_APPEND",
    "LIST_EXTEND",
    "BUILD_SET",
    "SET_ADD",
    "SET_UPDATE",
    # Dict comprehensions: MAP_ADD probe/insert (CONT_MAP_ADD on pycore;
    # DICT_GROW → excore when load ≥ 2/3). DICT_UPDATE is always excore
    # (PY_TRAP_DICT_UPDATE).
    "MAP_ADD",
    "DICT_UPDATE",
    # Sequence unpack: UNPACK_SEQUENCE (fixed-count, LIST/TUPLE sources) and
    # UNPACK_EX (starred unpack; builds middle list on-pycore heap).
    "UNPACK_SEQUENCE",
    "UNPACK_EX",
}

DEFERRED_OPS: dict[str, str] = {
    "DICT_MERGE": "dict merge lowering is deferred",
    "BINARY_SLICE": "slice notation support is deferred",
    "STORE_SLICE": "slice assignment support is deferred",
}


@dataclass(frozen=True)
class RawInstruction:
    offset: int
    opcode: int
    arg8: int
    opname: str
    arg: int


@dataclass
class ImageBuildResult:
    module_code: Tagged
    globals_dict: Tagged
    program_slots: list[str]
    heap: HeapImageBuilder
    string_heap: StringHeapBuilder
    code_handles: dict[int, Tagged] = field(default_factory=dict)
    entry_slots: dict[int, int] = field(default_factory=dict)
    global_store_count: int = 0
    globals_slot_count: int = 0

    @property
    def heap_init_ptr(self) -> int:
        return self.heap.end_ptr


def require_python_3_14() -> None:
    if sys.version_info[:2] != REQUIRED_PY:
        raise RuntimeError(
            "PyCore image boot is pinned to CPython "
            f"{REQUIRED_PY[0]}.{REQUIRED_PY[1]}; running "
            f"{sys.version_info.major}.{sys.version_info.minor}"
        )


def iter_code_objects(co: types.CodeType) -> Iterable[types.CodeType]:
    yield co
    for const in co.co_consts:
        if isinstance(const, types.CodeType):
            yield from iter_code_objects(const)


def iter_raw_instructions(co: types.CodeType) -> Iterable[RawInstruction]:
    """Yield raw two-byte code units with EXTENDED_ARG folded for validation."""
    extended = 0
    code = co.co_code
    if len(code) % 2:
        raise ValueError(f"code object {co.co_name!r} has odd co_code length")
    for offset in range(0, len(code), 2):
        op = code[offset]
        arg8 = code[offset + 1]
        opname = dis.opname[op]
        if op == OP_EXTENDED_ARG:
            full_arg = (extended << 8) | arg8
            yield RawInstruction(offset, op, arg8, opname, full_arg)
            extended = full_arg
            continue

        full_arg = (extended << 8) | arg8 if extended else arg8
        yield RawInstruction(offset, op, arg8, opname, full_arg)
        extended = 0


def _is_supported_opname(opname: str) -> bool:
    if opname.startswith("LOAD_FAST"):
        return True
    if opname.startswith("JUMP_"):
        return True
    if opname.startswith("POP_JUMP_"):
        return True
    return opname in SUPPORTED_OPS


def validate_code_object(co: types.CodeType) -> None:
    for ins in iter_raw_instructions(co):
        if ins.opname == "CACHE":
            continue
        if ins.opname in DEFERRED_OPS:
            raise ValueError(
                f"Deferred opcode {ins.opname!r} in code object {co.co_name!r} "
                f"at bytecode offset {ins.offset}: {DEFERRED_OPS[ins.opname]}"
            )
        if ins.opname == "SET_FUNCTION_ATTRIBUTE":
            raise ValueError(
                "Unsupported opcode 'SET_FUNCTION_ATTRIBUTE' in code object "
                f"{co.co_name!r} at bytecode offset {ins.offset}: function "
                "defaults, annotations, and closures are not supported by the "
                "image-boot serializer"
            )
        if not _is_supported_opname(ins.opname):
            raise ValueError(
                f"Unsupported opcode {ins.opname!r} in code object {co.co_name!r} "
                f"at bytecode offset {ins.offset}"
            )
        if ins.opname == "BINARY_OP" and ins.arg not in SUPPORTED_BINARY_ARGS:
            raise ValueError(
                f"Unsupported BINARY_OP oparg {ins.arg} in code object "
                f"{co.co_name!r} at bytecode offset {ins.offset}"
            )
        if ins.opname == "COMPARE_OP" and ins.arg not in SUPPORTED_COMPARE_ARGS:
            raise ValueError(
                f"Unsupported COMPARE_OP oparg {ins.arg} in code object "
                f"{co.co_name!r} at bytecode offset {ins.offset}"
            )
        if ins.opname == "LOAD_CONST" and ins.arg >= len(co.co_consts):
            raise ValueError(
                f"LOAD_CONST index {ins.arg} out of range in code object "
                f"{co.co_name!r} at bytecode offset {ins.offset}"
            )
        if ins.opname in {"LOAD_NAME", "STORE_NAME", "STORE_GLOBAL"}:
            if ins.arg >= len(co.co_names):
                raise ValueError(
                    f"{ins.opname} name index {ins.arg} out of range in code "
                    f"object {co.co_name!r} at bytecode offset {ins.offset}"
                )
        if ins.opname == "LOAD_GLOBAL":
            namei = ins.arg >> 1
            if namei >= len(co.co_names):
                raise ValueError(
                    f"LOAD_GLOBAL name index {namei} out of range in code "
                    f"object {co.co_name!r} at bytecode offset {ins.offset}"
                )


def validate_code_tree(module_code: types.CodeType) -> None:
    for co in iter_code_objects(module_code):
        validate_code_object(co)


def transcode_code_units(co: types.CodeType) -> list[str]:
    """Transcode raw co_code units one-for-one into imem slots."""
    code = co.co_code
    if len(code) % 2:
        raise ValueError(f"code object {co.co_name!r} has odd co_code length")
    slots: list[str] = []
    for offset in range(0, len(code), 2):
        slots.append(format_imem_slot(code[offset], code[offset + 1]))
    return slots


def count_global_store_names(module_code: types.CodeType) -> set[str]:
    stored: set[str] = set()
    for co in iter_code_objects(module_code):
        for ins in iter_raw_instructions(co):
            if ins.opname in {"STORE_NAME", "STORE_GLOBAL"}:
                if ins.arg >= len(co.co_names):
                    raise ValueError(
                        f"{ins.opname} name index {ins.arg} out of range in "
                        f"code object {co.co_name!r} at bytecode offset {ins.offset}"
                    )
                stored.add(co.co_names[ins.arg])
    return stored


class _ImageSerializer:
    def __init__(self) -> None:
        # BOOT_RECORD_ADDR is 0x03e0 and the two tagged entries occupy 64 bytes,
        # so static image allocations must not start at the nominal 0x0400 base.
        static_base = max(HEAP_BASE, BOOT_RECORD_ADDR + 64)
        self.heap = HeapImageBuilder(base=static_base)
        self.string_heap = StringHeapBuilder()
        self.program_slots: list[str] = []
        self.code_handles: dict[int, Tagged] = {}
        self.entry_slots: dict[int, int] = {}

    def serialize_code(self, co: types.CodeType) -> Tagged:
        co_id = id(co)
        existing = self.code_handles.get(co_id)
        if existing is not None:
            return existing

        # A parent co_consts tuple can point at nested code-object handles only
        # after those code objects have been serialized into dmem.
        for const in co.co_consts:
            if isinstance(const, types.CodeType):
                self.serialize_code(const)

        entry_slot = len(self.program_slots)
        self.program_slots.extend(transcode_code_units(co))
        self.entry_slots[co_id] = entry_slot

        co_consts = self.heap.alloc_tuple(
            [self.serialize_constant(const, co) for const in co.co_consts]
        )
        co_names = self.heap.alloc_tuple(
            [tag_constant(name, self.string_heap) for name in co.co_names]
        )
        handle = self.heap.add_code_object(
            entry_slot,
            co_consts,
            co_names,
            stacksize=co.co_stacksize,
            nlocals=co.co_nlocals,
            argcount=co.co_argcount,
        )
        self.code_handles[co_id] = handle
        return handle

    def serialize_constant(self, value: object, owner: types.CodeType) -> Tagged:
        if isinstance(value, types.CodeType):
            return self.serialize_code(value)
        if isinstance(value, tuple):
            return self.heap.alloc_tuple(
                [self.serialize_constant(item, owner) for item in value]
            )
        if value is None:
            return TAG_NONE, 0
        if isinstance(value, (bool, int, float, str)):
            return tag_constant(value, self.string_heap)
        raise ValueError(
            f"Unsupported constant {value!r} of type {type(value).__name__} "
            f"in code object {owner.co_name!r}"
        )


def build_image_from_code(module_code: types.CodeType) -> ImageBuildResult:
    require_python_3_14()
    validate_code_tree(module_code)

    stored_names = count_global_store_names(module_code)
    globals_slot_count = dict_slot_count_for_stores(len(stored_names))

    serializer = _ImageSerializer()
    globals_dict = serializer.heap.alloc_empty_globals(len(stored_names))
    module_handle = serializer.serialize_code(module_code)
    serializer.heap.write_boot_record(module_handle, globals_dict)

    return ImageBuildResult(
        module_code=module_handle,
        globals_dict=globals_dict,
        program_slots=serializer.program_slots,
        heap=serializer.heap,
        string_heap=serializer.string_heap,
        code_handles=serializer.code_handles,
        entry_slots=serializer.entry_slots,
        global_store_count=len(stored_names),
        globals_slot_count=globals_slot_count,
    )


_INJECT_LFAC_PREFIX = "# pycore-inject: LOAD_FAST_AND_CLEAR "
_OP_LOAD_FAST = _OM["LOAD_FAST"]
_OP_LOAD_FAST_BORROW = _OM["LOAD_FAST_BORROW"]
_OP_LOAD_FAST_AND_CLEAR = _OM["LOAD_FAST_AND_CLEAR"]


def parse_lfac_inject_pragmas(source_text: str) -> list[tuple[str, str]]:
    """Return ``(func_name, local_name)`` pairs from ``# pycore-inject:`` lines."""
    pragmas: list[tuple[str, str]] = []
    for line in source_text.splitlines():
        stripped = line.strip()
        if not stripped.startswith(_INJECT_LFAC_PREFIX):
            continue
        rest = stripped[len(_INJECT_LFAC_PREFIX) :].strip()
        parts = rest.split()
        if len(parts) != 2:
            raise ValueError(
                "pycore-inject LOAD_FAST_AND_CLEAR expects "
                f"'<func> <local>', got {rest!r}"
            )
        pragmas.append((parts[0], parts[1]))
    return pragmas


def _rewrite_first_load_to_lfac(co: types.CodeType, local_name: str) -> types.CodeType:
    try:
        local_index = co.co_varnames.index(local_name)
    except ValueError as exc:
        raise ValueError(
            f"local {local_name!r} not found in code object {co.co_name!r}"
        ) from exc

    code = bytearray(co.co_code)
    for offset in range(0, len(code), 2):
        op = code[offset]
        arg = code[offset + 1]
        if op in (_OP_LOAD_FAST, _OP_LOAD_FAST_BORROW) and arg == local_index:
            code[offset] = _OP_LOAD_FAST_AND_CLEAR
            return co.replace(co_code=bytes(code))
    raise ValueError(
        f"no LOAD_FAST/LOAD_FAST_BORROW of {local_name!r} in "
        f"code object {co.co_name!r}"
    )


def _replace_code_by_name(
    co: types.CodeType, func_name: str, new_co: types.CodeType
) -> types.CodeType:
    if co.co_name == func_name:
        return new_co
    consts = list(co.co_consts)
    changed = False
    for i, const in enumerate(consts):
        if isinstance(const, types.CodeType):
            replaced = _replace_code_by_name(const, func_name, new_co)
            if replaced is not const:
                consts[i] = replaced
                changed = True
    if not changed:
        return co
    return co.replace(co_consts=tuple(consts))


def _find_code_by_name(co: types.CodeType, func_name: str) -> types.CodeType | None:
    if co.co_name == func_name:
        return co
    for const in co.co_consts:
        if isinstance(const, types.CodeType):
            found = _find_code_by_name(const, func_name)
            if found is not None:
                return found
    return None


def apply_lfac_injects(
    module_code: types.CodeType, source_text: str
) -> types.CodeType:
    """Apply ``# pycore-inject: LOAD_FAST_AND_CLEAR <func> <local>`` rewrites."""
    result = module_code
    for func_name, local_name in parse_lfac_inject_pragmas(source_text):
        target = _find_code_by_name(result, func_name)
        if target is None:
            raise ValueError(
                f"pycore-inject target function {func_name!r} not found"
            )
        rewritten = _rewrite_first_load_to_lfac(target, local_name)
        result = _replace_code_by_name(result, func_name, rewritten)
    return result


# Hand-assemble SET_ADD sequences (compile() only emits SET_ADD in
# comprehensions that need FOR_ITER). Pragma:
#   # pycore-inject: SET_ADD_SEQ <func> <int> <int> ...
#   optional trailing keywords: RET=0 | CONTAINS
# CONTAINS: after adds, return bitmask (1<<i) for each value present via `in`.
_INJECT_SET_ADD_PREFIX = "# pycore-inject: SET_ADD_SEQ "
_OP_RESUME = _OM["RESUME"]
_OP_BUILD_SET = _OM["BUILD_SET"]
_OP_SET_ADD = _OM["SET_ADD"]
_OP_LOAD_SMALL_INT = _OM["LOAD_SMALL_INT"]
_OP_STORE_FAST = _OM["STORE_FAST"]
_OP_LOAD_FAST = _OM["LOAD_FAST"]
_OP_CONTAINS_OP = _OM["CONTAINS_OP"]
_OP_BINARY_OP = _OM["BINARY_OP"]
_OP_RETURN_VALUE = _OM["RETURN_VALUE"]


def parse_set_add_seq_pragmas(
    source_text: str,
) -> list[tuple[str, list[int], str]]:
    """Return ``(func, ints, mode)`` with mode ``RET`` or ``CONTAINS``."""
    out: list[tuple[str, list[int], str]] = []
    for line in source_text.splitlines():
        stripped = line.strip()
        if not stripped.startswith(_INJECT_SET_ADD_PREFIX):
            continue
        rest = stripped[len(_INJECT_SET_ADD_PREFIX) :].strip().split()
        if len(rest) < 2:
            raise ValueError(
                "pycore-inject SET_ADD_SEQ expects '<func> <int>...' "
                f"got {stripped!r}"
            )
        func = rest[0]
        mode = "RET"
        nums: list[int] = []
        for tok in rest[1:]:
            if tok.startswith("MODE="):
                mode = tok.split("=", 1)[1]
            else:
                nums.append(int(tok))
        if mode not in ("RET", "CONTAINS"):
            raise ValueError(f"SET_ADD_SEQ MODE must be RET or CONTAINS, got {mode}")
        out.append((func, nums, mode))
    return out


def _build_set_add_seq_code(
    template: types.CodeType, nums: list[int], mode: str
) -> types.CodeType:
    """Replace ``template`` bytecode with BUILD_SET0 + SET_ADDs (+ contains)."""
    code = bytearray()
    # CPython 3.14 CodeType.replace force-pads inline caches by overwriting the
    # following word(s). Emit CACHE entries explicitly (same layout as compile()).
    _contains_caches = sum(_opcode_module._cache_format["CONTAINS_OP"].values())
    _binary_caches = sum(_opcode_module._cache_format["BINARY_OP"].values())

    def emit(op: int, arg: int = 0) -> None:
        if arg > 255:
            raise ValueError(f"oparg {arg} exceeds 8 bits in SET_ADD_SEQ")
        code.append(op)
        code.append(arg & 0xFF)

    def emit_caches(n: int) -> None:
        for _ in range(n):
            emit(OP_CACHE, 0)

    emit(_OP_RESUME, 0)
    emit(_OP_BUILD_SET, 0)
    emit(_OP_STORE_FAST, 0)  # s
    for n in nums:
        if n < 0 or n > 255:
            raise ValueError(f"SET_ADD_SEQ ints must be 0..255, got {n}")
        emit(_OP_LOAD_FAST, 0)
        emit(_OP_LOAD_SMALL_INT, n)
        emit(_OP_SET_ADD, 1)
    if mode == "CONTAINS":
        # Start with INT 0 so BOOL+INT promotions yield INT (not BOOL).
        emit(_OP_LOAD_SMALL_INT, 0)
        for n in nums:
            emit(_OP_LOAD_SMALL_INT, n)
            emit(_OP_LOAD_FAST, 0)
            emit(_OP_CONTAINS_OP, 0)  # bool
            emit_caches(_contains_caches)
            emit(_OP_BINARY_OP, 0)  # +
            emit_caches(_binary_caches)
        miss = (max(nums) + 1) if nums else 0
        if miss <= 255:
            emit(_OP_LOAD_SMALL_INT, miss)
            emit(_OP_LOAD_FAST, 0)
            emit(_OP_CONTAINS_OP, 1)  # not in → True
            emit_caches(_contains_caches)
            emit(_OP_BINARY_OP, 0)
            emit_caches(_binary_caches)
        emit(_OP_RETURN_VALUE, 0)
    else:
        emit(_OP_LOAD_SMALL_INT, 0)
        emit(_OP_RETURN_VALUE, 0)

    # Locals: one slot for the set. Stack size: generous.
    return template.replace(
        co_code=bytes(code),
        co_varnames=("s",),
        co_nlocals=1,
        co_stacksize=max(8, template.co_stacksize),
        co_names=(),
        co_consts=(None,),
    )


def apply_set_add_seq_injects(
    module_code: types.CodeType, source_text: str
) -> types.CodeType:
    result = module_code
    for func_name, nums, mode in parse_set_add_seq_pragmas(source_text):
        target = _find_code_by_name(result, func_name)
        if target is None:
            raise ValueError(
                f"pycore-inject SET_ADD_SEQ target {func_name!r} not found"
            )
        rewritten = _build_set_add_seq_code(target, nums, mode)
        result = _replace_code_by_name(result, func_name, rewritten)
    return result


# Hand-assemble MAP_ADD sequences (dict comprehensions emit RERAISE/exception
# handling that pycore does not support).  Pragma:
#   # pycore-inject: MAP_ADD_SEQ <func> (<key>,<value>) (<key>,<value>) ...
#   optional trailing keyword: SUBSCR (verify result by reading dict[key])
# SUBSCR: after adds, return sum of result[key] for each pair.
_INJECT_MAP_ADD_PREFIX = "# pycore-inject: MAP_ADD_SEQ "
_OP_BUILD_MAP = _OM["BUILD_MAP"]
_OP_MAP_ADD   = _OM["MAP_ADD"]


def parse_map_add_seq_pragmas(
    source_text: str,
) -> list[tuple[str, list[tuple[int, int]], str]]:
    """Return ``(func, pairs, mode)`` with mode ``RET`` or ``SUBSCR``."""
    out: list[tuple[str, list[tuple[int, int]], str]] = []
    for line in source_text.splitlines():
        stripped = line.strip()
        if not stripped.startswith(_INJECT_MAP_ADD_PREFIX):
            continue
        rest = stripped[len(_INJECT_MAP_ADD_PREFIX) :].strip()
        tokens = rest.split()
        if not tokens:
            raise ValueError(f"MAP_ADD_SEQ expects '<func> (k,v)...' got {stripped!r}")
        func = tokens[0]
        mode = "RET"
        pairs: list[tuple[int, int]] = []
        for tok in tokens[1:]:
            if tok.startswith("MODE="):
                mode = tok.split("=", 1)[1]
            else:
                if not (tok.startswith("(") and tok.endswith(")") and "," in tok):
                    raise ValueError(f"MAP_ADD_SEQ pair must be '(k,v)', got {tok!r}")
                k_s, v_s = tok[1:-1].split(",", 1)
                pairs.append((int(k_s.strip()), int(v_s.strip())))
        if mode not in ("RET", "SUBSCR"):
            raise ValueError(f"MAP_ADD_SEQ MODE must be RET or SUBSCR, got {mode}")
        out.append((func, pairs, mode))
    return out


def _build_map_add_seq_code(
    template: types.CodeType, pairs: list[tuple[int, int]], mode: str
) -> types.CodeType:
    """Replace template bytecode with BUILD_MAP + MAP_ADD sequence."""
    code = bytearray()
    _subscr_caches = sum(_opcode_module._cache_format.get("BINARY_OP", {}).values())
    _binary_caches = _subscr_caches

    def emit(op: int, arg: int = 0) -> None:
        if arg > 255:
            raise ValueError(f"oparg {arg} exceeds 8 bits in MAP_ADD_SEQ")
        code.append(op)
        code.append(arg & 0xFF)

    def emit_caches(n: int) -> None:
        for _ in range(n):
            emit(OP_CACHE, 0)

    emit(_OP_RESUME, 0)
    emit(_OP_BUILD_MAP, 0)
    emit(_OP_STORE_FAST, 0)  # d (local 0)
    for k, v in pairs:
        if not (0 <= k <= 255 and 0 <= v <= 255):
            raise ValueError(f"MAP_ADD_SEQ key/val must be 0..255, got ({k},{v})")
        # Stack before MAP_ADD 1: [dict, key, value]
        #   tos_r=3; dict at RF[3-2-1]=RF[0]; key at RF[1]; value at RF[2].
        emit(_OP_LOAD_FAST, 0)       # push dict handle
        emit(_OP_LOAD_SMALL_INT, k)  # push key
        emit(_OP_LOAD_SMALL_INT, v)  # push value (TOS)
        emit(_OP_MAP_ADD, 1)         # dict at RF[tos-2-1]=RF[tos-3]; pop key+val
    if mode == "SUBSCR":
        # Sum up d[k] for each pair.  BINARY_OP NB_SUBSCR (oparg=26).
        _nbarg_subscr: int = 0
        for i, entry in enumerate(getattr(_opcode_module, "_nb_ops", [])):
            if "SUBSCR" in str(entry[0]).upper():
                _nbarg_subscr = i
                break
        emit(_OP_LOAD_SMALL_INT, 0)  # accumulator
        for k, _ in pairs:
            emit(_OP_LOAD_FAST, 0)
            emit(_OP_LOAD_SMALL_INT, k)
            emit(_OP_BINARY_OP, _nbarg_subscr)  # d[k]
            emit_caches(_binary_caches)
            emit(_OP_BINARY_OP, 0)  # +
            emit_caches(_binary_caches)
        emit(_OP_RETURN_VALUE, 0)
    else:
        emit(_OP_LOAD_SMALL_INT, 0)
        emit(_OP_RETURN_VALUE, 0)

    return template.replace(
        co_code=bytes(code),
        co_varnames=("d",),
        co_nlocals=1,
        co_stacksize=max(8, template.co_stacksize),
        co_names=(),
        co_consts=(None,),
    )


def apply_map_add_seq_injects(
    module_code: types.CodeType, source_text: str
) -> types.CodeType:
    result = module_code
    for func_name, pairs, mode in parse_map_add_seq_pragmas(source_text):
        target = _find_code_by_name(result, func_name)
        if target is None:
            raise ValueError(
                f"pycore-inject MAP_ADD_SEQ target {func_name!r} not found"
            )
        rewritten = _build_map_add_seq_code(target, pairs, mode)
        result = _replace_code_by_name(result, func_name, rewritten)
    return result


def build_image_from_source_text(source_text: str, filename: str) -> ImageBuildResult:
    module_code = compile(source_text, filename, "exec")
    module_code = apply_lfac_injects(module_code, source_text)
    module_code = apply_set_add_seq_injects(module_code, source_text)
    module_code = apply_map_add_seq_injects(module_code, source_text)
    return build_image_from_code(module_code)


def build_image_from_source(source: pathlib.Path) -> ImageBuildResult:
    source = pathlib.Path(source)
    source_text = source.read_text(encoding="utf-8")
    return build_image_from_source_text(source_text, str(source))


def write_text(path: pathlib.Path, text: str) -> None:
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="ascii")


def write_program_hex(path: pathlib.Path, program_slots: Iterable[str]) -> None:
    lines = list(program_slots)
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


def write_meta(
    path: pathlib.Path,
    result: ImageBuildResult,
    *,
    expected_tag: int | None = None,
    expected_value: int | None = None,
) -> None:
    lines = [f"HEAP_INIT_PTR={result.heap_init_ptr}"]
    if expected_tag is not None:
        lines.append(f"EXPECTED_TAG={expected_tag}")
    if expected_value is not None:
        lines.append(f"EXPECTED_VALUE={expected_value & VAL_MASK}")
    write_text(path, "\n".join(lines) + "\n")


def write_image_outputs(
    result: ImageBuildResult,
    *,
    program_hex: pathlib.Path,
    dmem_hex: pathlib.Path,
    string_hex: pathlib.Path,
    meta: pathlib.Path,
    expected_tag: int | None = None,
    expected_value: int | None = None,
) -> None:
    write_program_hex(program_hex, result.program_slots)
    result.heap.write_hex(dmem_hex)
    write_string_hex(string_hex, result.string_heap)
    write_meta(meta, result, expected_tag=expected_tag, expected_value=expected_value)


def image_from_source(
    *,
    source: pathlib.Path,
    program_hex: pathlib.Path,
    dmem_hex: pathlib.Path,
    string_hex: pathlib.Path,
    meta: pathlib.Path,
) -> ImageBuildResult:
    result = build_image_from_source(source)
    write_image_outputs(
        result,
        program_hex=program_hex,
        dmem_hex=dmem_hex,
        string_hex=string_hex,
        meta=meta,
    )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--program-hex", required=True)
    parser.add_argument("--dmem-hex", required=True)
    parser.add_argument("--string-hex", required=True)
    parser.add_argument("--meta", required=True)
    args = parser.parse_args()

    require_python_3_14()
    image_from_source(
        source=pathlib.Path(args.source),
        program_hex=pathlib.Path(args.program_hex),
        dmem_hex=pathlib.Path(args.dmem_hex),
        string_hex=pathlib.Path(args.string_hex),
        meta=pathlib.Path(args.meta),
    )


if __name__ == "__main__":
    main()
