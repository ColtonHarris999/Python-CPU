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

SUPPORTED_OPS = {
    "RESUME",
    "CACHE",
    "EXTENDED_ARG",
    "LOAD_CONST",
    "STORE_FAST",
    "LOAD_SMALL_INT",
    "POP_TOP",
    "POP_ITER",
    "NOT_TAKEN",
    "TO_BOOL",
    "BINARY_OP",
    "COMPARE_OP",
    "BUILD_LIST",
    "BUILD_MAP",
    "BUILD_TUPLE",
    "STORE_SUBSCR",
    "CALL",
    "RETURN_VALUE",
    "LOAD_GLOBAL",
    "LOAD_NAME",
    "STORE_NAME",
    "STORE_GLOBAL",
    "PUSH_NULL",
    "MAKE_FUNCTION",
    # LIST_APPEND / LIST_EXTEND fast-path (spare capacity) / grow-trap are
    # implemented in CONT_LIST_APPEND / CONT_LIST_EXTEND (pycore_core.sv).
    # LIST_APPEND still only appears inside comprehensions (FOR_ITER/GET_ITER
    # deferred). LIST_EXTEND is emitted by list-display unpack forms such as
    # `[1, 2, *x]` and `[*a, *b]` — those are accepted here. Sources must be
    # LIST or TUPLE (no iterator protocol yet).
    "LIST_APPEND",
    "LIST_EXTEND",
}

DEFERRED_OPS: dict[str, str] = {
    "MAP_ADD": "dict-comprehension MAP_ADD lowering is deferred",
    "DICT_UPDATE": "dict update/unpack lowering is deferred",
    "DICT_MERGE": "dict merge lowering is deferred",
    "DELETE_SUBSCR": "subscript deletion is deferred",
    "CONTAINS_OP": "in / not-in operator support is deferred",
    "BINARY_SLICE": "slice notation support is deferred",
    "STORE_SLICE": "slice assignment support is deferred",
    "BUILD_SET": "set literals are deferred",
    "SET_ADD": "set.add/set-comprehension lowering is deferred",
    "SET_UPDATE": "set.update lowering is deferred",
}

STACK_OP_REJECTS = {"COPY", "SWAP"}


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
        if ins.opname in STACK_OP_REJECTS:
            raise ValueError(
                f"Unsupported stack manipulation opcode {ins.opname!r} in code "
                f"object {co.co_name!r} at bytecode offset {ins.offset}"
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


def build_image_from_source_text(source_text: str, filename: str) -> ImageBuildResult:
    module_code = compile(source_text, filename, "exec")
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
