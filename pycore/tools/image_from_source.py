#!/usr/bin/env python3.14
"""Build PyCore CPython module images from Python source.

This is the primary image-boot path.  It preserves CPython 3.14 wordcode
one-for-one: every raw two-byte ``co_code`` unit becomes one 64-bit imem slot.
"""

from __future__ import annotations

import argparse
import ast
import dis
import inspect
import opcode as _opcode_module
import pathlib
import sys
import types
from dataclasses import dataclass, field
from typing import Iterable

from encoding import (
    BI_BYTEARRAY,
    BI_FROM_BYTES,
    BI_LEN,
    BI_MAX,
    BI_PRINT,
    BI_RANGE,
    BI_SET,
    BI_TO_BYTES,
    HEAP_BASE,
    STRING_MEM_BYTES,
    TAG_INT,
    VAL_MASK,
    StringHeapBuilder,
    dict_slot_count_for_stores,
    format_imem_slot,
    int_value,
    make_none,
    make_range_inline,
    make_range_tuple,
    range_fits_inline,
    tag_constant,
)
from heap_image import HeapImageBuilder, Tagged, dict_min_slots


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
    "UNARY_INVERT",
    "UNARY_NEGATIVE",
    "BINARY_OP",
    "COMPARE_OP",
    "IS_OP",
    "BUILD_LIST",
    "BUILD_MAP",
    "BUILD_TUPLE",
    "UNPACK_SEQUENCE",
    "UNPACK_EX",
    "STORE_SUBSCR",
    "DELETE_SUBSCR",
    "CONTAINS_OP",
    "COPY",
    "SWAP",
    "CALL",
    "CALL_KW",
    "CALL_FUNCTION_EX",
    "DICT_MERGE",
    "DICT_UPDATE",
    "MAP_ADD",
    # CPython 3.14 emits LOAD_CONST + RETURN_VALUE; RETURN_CONST is absent.
    "RETURN_VALUE",
    "RAISE_VARARGS",
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
    # Attribute protocol (M2): instance/type dict probe + MRO.
    "LOAD_ATTR",
    "STORE_ATTR",
    "DELETE_ATTR",
}

DEFERRED_OPS: dict[str, str] = {
    "BINARY_SLICE": "slice notation support is deferred",
    "STORE_SLICE": "slice assignment support is deferred",
    # Classes are emitted at image-build time (M4 ClassImageBuilder); hardware
    # LOAD_BUILD_CLASS needs frame-local namespaces and is intentionally out.
    "LOAD_BUILD_CLASS": (
        "dynamic class creation is deferred; module-level classes are "
        "serialized at image-build time"
    ),
    "LOAD_COMMON_CONSTANT": "LOAD_COMMON_CONSTANT is not part of the image-boot subset",
    "LOAD_SPECIAL": "LOAD_SPECIAL is not part of the image-boot subset",
    "LOAD_SUPER_ATTR": "super() attribute lookup is deferred",
    "CALL_INTRINSIC_1": "CALL_INTRINSIC_1 is deferred except INTRINSIC_LIST_TO_TUPLE (arg 6)",
    "CALL_INTRINSIC_2": "CALL_INTRINSIC_2 is deferred",
    "IMPORT_NAME": "imports are deferred",
    "IMPORT_FROM": "imports are deferred",
    "SETUP_FINALLY": "exception handling is deferred",
    "PUSH_EXC_INFO": "exception handling is deferred",
    "CHECK_EXC_MATCH": "exception handling is deferred",
    "RERAISE": "exception handling is deferred",
    "WITH_EXCEPT_START": "context-manager exception path is deferred",
    "YIELD_VALUE": "generators are deferred",
    "SEND": "generators/coroutines are deferred",
    "GET_AWAITABLE": "async/await is deferred",
    "FORMAT_WITH_SPEC": "format-spec f-strings are deferred",
    "MATCH_CLASS": "structural pattern matching is deferred",
    "MATCH_KEYS": "structural pattern matching is deferred",
    "MATCH_MAPPING": "structural pattern matching is deferred",
    "MATCH_SEQUENCE": "structural pattern matching is deferred",
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
    builtins_dict: Tagged
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
    if co.co_flags & inspect.CO_VARKEYWORDS:
        raise ValueError(
            f"Unsupported variadic arguments in code object {co.co_name!r}: "
            "CO_VARKEYWORDS (**kwargs)"
        )

    for ins in iter_raw_instructions(co):
        if ins.opname == "CACHE":
            continue
        if ins.opname == "CALL_INTRINSIC_1":
            if ins.arg == 6:
                continue
            raise ValueError(
                f"Deferred opcode {ins.opname!r} in code object {co.co_name!r} "
                f"at bytecode offset {ins.offset}: {DEFERRED_OPS[ins.opname]}"
            )
        if ins.opname in DEFERRED_OPS:
            raise ValueError(
                f"Deferred opcode {ins.opname!r} in code object {co.co_name!r} "
                f"at bytecode offset {ins.offset}: {DEFERRED_OPS[ins.opname]}"
            )
        if ins.opname == "SET_FUNCTION_ATTRIBUTE":
            # Folded to NOP before validate when flag==defaults (1) or
            # kwdefaults (2). Any other flag is rejected here.
            if ins.arg not in (_SFA_FLAG_DEFAULTS, _SFA_FLAG_KWDEFAULTS):
                raise ValueError(
                    "Unsupported SET_FUNCTION_ATTRIBUTE flag "
                    f"{ins.arg} in code object {co.co_name!r} at bytecode "
                    f"offset {ins.offset}: only defaults (flag 1) and "
                    "kwdefaults (flag 2) are folded at image-build time; "
                    "closures/annotations "
                    "are not supported"
                )
            raise ValueError(
                "Internal error: SET_FUNCTION_ATTRIBUTE should have "
                f"been folded before validate in {co.co_name!r} at offset "
                f"{ins.offset}"
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
        if ins.opname == "LOAD_ATTR":
            namei = ins.arg >> 1
            if namei >= len(co.co_names):
                raise ValueError(
                    f"LOAD_ATTR name index {namei} out of range in code "
                    f"object {co.co_name!r} at bytecode offset {ins.offset}"
                )
        if ins.opname in {"STORE_ATTR", "DELETE_ATTR"}:
            if ins.arg >= len(co.co_names):
                raise ValueError(
                    f"{ins.opname} name index {ins.arg} out of range in code "
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
    def __init__(
        self,
        defaults_map: dict[int, tuple] | None = None,
        kwdefaults_map: dict[int, dict] | None = None,
        type_refs: dict[str, Tagged] | None = None,
    ) -> None:
        # HEAP_BASE is defined as the first byte after the boot record.
        static_base = HEAP_BASE
        self.heap = HeapImageBuilder(base=static_base)
        self.string_heap = StringHeapBuilder()
        self.program_slots: list[str] = []
        self.code_handles: dict[int, Tagged] = {}
        self.entry_slots: dict[int, int] = {}
        self.defaults_map: dict[int, tuple] = defaults_map or {}
        self.kwdefaults_map: dict[int, dict] = kwdefaults_map or {}
        self.type_refs: dict[str, Tagged] = type_refs if type_refs is not None else {}

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
        co_varnames = self.heap.alloc_tuple(
            [tag_constant(name, self.string_heap) for name in co.co_varnames]
        )
        defaults_py = self.defaults_map.get(co_id, ())
        co_defaults = self.heap.alloc_tuple(
            [self.serialize_constant(d, co) for d in defaults_py]
        )
        kwdefaults_py = self.kwdefaults_map.get(co_id, {})
        co_kwdefaults = self.heap.alloc_dict(
            [
                (
                    tag_constant(str(name), self.string_heap),
                    self.serialize_constant(default, co),
                )
                for name, default in kwdefaults_py.items()
            ],
            slot_count=dict_min_slots(max(len(kwdefaults_py), 1)),
        )
        co_exceptiontable = self.heap.alloc_tuple(
            [(TAG_INT, int_value(byte)) for byte in co.co_exceptiontable]
        )
        handle = self.heap.add_code_object(
            entry_slot,
            co_consts,
            co_names,
            co_varnames,
            stacksize=co.co_stacksize,
            nlocals=co.co_nlocals,
            argcount=co.co_argcount,
            kwonlyargcount=co.co_kwonlyargcount,
            varargs=bool(co.co_flags & inspect.CO_VARARGS),
            co_defaults=co_defaults,
            co_kwdefaults=co_kwdefaults,
            co_exceptiontable=co_exceptiontable,
        )
        self.code_handles[co_id] = handle
        return handle

    def serialize_constant(self, value: object, owner: types.CodeType) -> Tagged:
        if isinstance(value, _PyCoreTypeRef):
            handle = self.type_refs.get(value.name)
            if handle is None:
                raise ValueError(
                    f"Unresolved _PyCoreTypeRef({value.name!r}) in code object "
                    f"{owner.co_name!r}; type must be allocated before serialize"
                )
            return handle
        if isinstance(value, types.CodeType):
            return self.serialize_code(value)
        if isinstance(value, tuple):
            return self.heap.alloc_tuple(
                [self.serialize_constant(item, owner) for item in value]
            )
        if value is None:
            return make_none()
        if isinstance(value, range):
            if range_fits_inline(value):
                return make_range_inline(value.start, value.stop, value.step)
            triple = self.heap.alloc_tuple([
                (TAG_INT, int_value(value.start)),
                (TAG_INT, int_value(value.stop)),
                (TAG_INT, int_value(value.step)),
            ])
            return make_range_tuple(triple[1] & ((1 << 64) - 1))
        if isinstance(value, (bool, int, float, complex, str)):
            return tag_constant(value, self.string_heap)
        raise ValueError(
            f"Unsupported constant {value!r} of type {type(value).__name__} "
            f"in code object {owner.co_name!r}"
        )

    def alloc_class_types(self, class_specs: list[ClassBuildSpec]) -> None:
        """Serialize method codes, then allocate OBK_TYPE into ``type_refs``.

        Staticmethods are stored as ``OBK_BUILTIN`` with ``builtin_id=0`` and
        ``bound_self`` holding the ``CODE_OBJECT`` handle (LOAD_ATTR unwraps
        without binding ``self``).
        """
        for spec in class_specs:
            attr_pairs: list[tuple[Tagged, Tagged]] = []
            for attr_name, const_val in spec.constants.items():
                if const_val is None:
                    tagged: Tagged = make_none()
                elif isinstance(const_val, (bool, int, float, complex, str)):
                    tagged = tag_constant(const_val, self.string_heap)
                else:
                    raise ValueError(
                        f"class {spec.name!r}: unsupported constant "
                        f"{attr_name!r}={const_val!r}"
                    )
                attr_pairs.append(
                    (tag_constant(attr_name, self.string_heap), tagged)
                )
            for meth_name, meth_co in spec.methods.items():
                handle = self.serialize_code(meth_co)
                attr_pairs.append(
                    (tag_constant(meth_name, self.string_heap), handle)
                )
            for meth_name, meth_co in spec.static_methods.items():
                code_handle = self.serialize_code(meth_co)
                # Convention: builtin_id=0 ⇒ staticmethod wrapper; field1=CODE.
                builtin = self.heap.alloc_builtin(0, code_handle)
                attr_pairs.append(
                    (tag_constant(meth_name, self.string_heap), builtin)
                )
            n_keys = max(len(attr_pairs), 1)
            tp_dict = self.heap.alloc_dict(
                attr_pairs, slot_count=dict_min_slots(n_keys)
            )
            tp_name = tag_constant(spec.name, self.string_heap)
            handle = self.heap.alloc_type(tp_name, tp_dict=tp_dict)
            self.type_refs[spec.name] = handle


@dataclass(frozen=True)
class SeedTypeSpec:
    """Build-time OBK_TYPE seed.

    ``# pycore-inject: SEED_TYPE Name [base=Base] [attr=int ...]``
    """

    name: str
    base_name: str | None = None
    attrs: tuple[tuple[str, int], ...] = ()


@dataclass(frozen=True)
class SeedTypeMethodSpec:
    """Attach a module-level function to a seeded type's tp_dict.

    ``# pycore-inject: SEED_TYPE_METHOD T meth = helper``
    """

    type_name: str
    attr_name: str
    func_name: str


@dataclass(frozen=True)
class SeedInstanceSpec:
    """Build-time OBK_INSTANCE seed.

    ``# pycore-inject: SEED_INSTANCE name [type=T] [slots=N] [attr=int ...]``
    """

    name: str
    type_name: str | None = None
    slots: int = 4
    attrs: tuple[tuple[str, int], ...] = ()


@dataclass(frozen=True)
class SeedSpecs:
    types: tuple[SeedTypeSpec, ...] = ()
    type_methods: tuple[SeedTypeMethodSpec, ...] = ()
    instances: tuple[SeedInstanceSpec, ...] = ()

    @property
    def global_names(self) -> set[str]:
        names = {t.name for t in self.types}
        names.update(i.name for i in self.instances)
        return names


_INJECT_SEED_TYPE_PREFIX = "# pycore-inject: SEED_TYPE "
_INJECT_SEED_TYPE_METHOD_PREFIX = "# pycore-inject: SEED_TYPE_METHOD "
_INJECT_SEED_INSTANCE_PREFIX = "# pycore-inject: SEED_INSTANCE "
_OP_NOP = _OM["NOP"]
_OP_MAKE_FUNCTION = _OM["MAKE_FUNCTION"]
_OP_SET_FUNCTION_ATTRIBUTE = _OM["SET_FUNCTION_ATTRIBUTE"]
_OP_LOAD_CONST = _OM["LOAD_CONST"]
_OP_PUSH_NULL = _OM["PUSH_NULL"]
_OP_CALL = _OM["CALL"]
_OP_STORE_NAME = _OM["STORE_NAME"]
_OP_LOAD_BUILD_CLASS = _OM["LOAD_BUILD_CLASS"]
_OP_BUILD_MAP = _OM["BUILD_MAP"]
_SFA_FLAG_DEFAULTS = 1
_SFA_FLAG_KWDEFAULTS = 2


@dataclass(frozen=True)
class _PyCoreTypeRef:
    """Placeholder in co_consts resolved to an OBK_TYPE handle at serialize time."""

    name: str


@dataclass
class ClassBuildSpec:
    """Module-level class folded at image-build time into an OBK_TYPE."""

    name: str
    methods: dict[str, types.CodeType]
    static_methods: dict[str, types.CodeType]
    constants: dict[str, object]
    # id(code) → defaults tuple captured from host function.__defaults__
    method_defaults: dict[int, tuple] = field(default_factory=dict)
    # id(code) → kwdefaults dict captured from host function.__kwdefaults__
    method_kwdefaults: dict[int, dict] = field(default_factory=dict)


def _parse_seed_kv_tokens(tokens: list[str]) -> tuple[dict[str, str], list[tuple[str, int]]]:
    """Split ``key=val`` tokens into options vs int attribute pairs."""
    opts: dict[str, str] = {}
    attrs: list[tuple[str, int]] = []
    for tok in tokens:
        if "=" not in tok:
            raise ValueError(f"seed token must be key=value, got {tok!r}")
        key, val = tok.split("=", 1)
        if key in {"type", "slots", "base"}:
            opts[key] = val
            continue
        attrs.append((key, int(val)))
    return opts, attrs


def parse_seed_pragmas(source_text: str) -> SeedSpecs:
    """Parse SEED_TYPE / SEED_TYPE_METHOD / SEED_INSTANCE pragmas."""
    types: list[SeedTypeSpec] = []
    type_methods: list[SeedTypeMethodSpec] = []
    instances: list[SeedInstanceSpec] = []
    for line in source_text.splitlines():
        stripped = line.strip()
        if stripped.startswith(_INJECT_SEED_TYPE_METHOD_PREFIX):
            rest = stripped[len(_INJECT_SEED_TYPE_METHOD_PREFIX) :].strip()
            if "=" not in rest:
                raise ValueError(
                    "SEED_TYPE_METHOD expects '<Type> <attr> = <func>', "
                    f"got {stripped!r}"
                )
            left, func = rest.split("=", 1)
            parts = left.split()
            if len(parts) != 2 or not func.strip():
                raise ValueError(
                    "SEED_TYPE_METHOD expects '<Type> <attr> = <func>', "
                    f"got {stripped!r}"
                )
            type_methods.append(
                SeedTypeMethodSpec(parts[0], parts[1], func.strip())
            )
        elif stripped.startswith(_INJECT_SEED_TYPE_PREFIX):
            rest = stripped[len(_INJECT_SEED_TYPE_PREFIX) :].strip().split()
            if not rest:
                raise ValueError(
                    "SEED_TYPE expects '<Name> [base=Base] [attr=int ...]'"
                )
            opts, attrs = _parse_seed_kv_tokens(rest[1:])
            types.append(
                SeedTypeSpec(
                    rest[0],
                    base_name=opts.get("base"),
                    attrs=tuple(attrs),
                )
            )
        elif stripped.startswith(_INJECT_SEED_INSTANCE_PREFIX):
            rest = stripped[len(_INJECT_SEED_INSTANCE_PREFIX) :].strip().split()
            if not rest:
                raise ValueError(
                    "SEED_INSTANCE expects '<name> [type=T] [slots=N] [attr=int ...]'"
                )
            opts, attrs = _parse_seed_kv_tokens(rest[1:])
            slots = int(opts.get("slots", "4"))
            if slots < 0 or (slots > 0 and (slots & (slots - 1)) != 0):
                raise ValueError(
                    f"SEED_INSTANCE slots must be 0 or power of two, got {slots}"
                )
            instances.append(
                SeedInstanceSpec(
                    rest[0],
                    type_name=opts.get("type"),
                    slots=slots,
                    attrs=tuple(attrs),
                )
            )
    return SeedSpecs(tuple(types), tuple(type_methods), tuple(instances))


def fold_function_defaults(
    module_code: types.CodeType,
) -> tuple[types.CodeType, dict[int, tuple], dict[int, dict]]:
    """Fold ``SET_FUNCTION_ATTRIBUTE`` defaults into maps; NOP-pad the ops.

    Patterns (CPython 3.14)::

        LOAD_CONST <defaults_tuple>
        LOAD_CONST <code>
        MAKE_FUNCTION
        SET_FUNCTION_ATTRIBUTE 1 (defaults)

    and, for keyword-only defaults::

        <kwdefaults BUILD_MAP producer>
        LOAD_CONST <code>
        MAKE_FUNCTION
        SET_FUNCTION_ATTRIBUTE 2 (kwdefaults)

    When both defaults and kwdefaults are present, the positional defaults
    producer sits lower on the stack and CPython typically emits
    ``SET_FUNCTION_ATTRIBUTE 2`` followed by ``SET_FUNCTION_ATTRIBUTE 1``.

    Becomes::

        NOP
        LOAD_CONST <code>
        MAKE_FUNCTION
        NOP

    Returns ``(rewritten_module, defaults_map, kwdefaults_map)``.
    """
    defaults_map: dict[int, tuple] = {}
    kwdefaults_map: dict[int, dict] = {}

    def fold_one(co: types.CodeType) -> types.CodeType:
        code = bytearray(co.co_code)
        consts = list(co.co_consts)

        def nop_span(start: int, end: int) -> None:
            for off in range(start, end, 2):
                code[off] = _OP_NOP
                code[off + 1] = 0

        def parse_attr_producer(end: int) -> tuple[int, object]:
            if end < 2:
                raise ValueError(
                    f"truncated SET_FUNCTION_ATTRIBUTE producer in {co.co_name!r}"
                )
            op = code[end - 2]
            arg = code[end - 1]
            if op == _OP_LOAD_CONST:
                if arg >= len(consts):
                    raise ValueError(
                        f"function attribute LOAD_CONST index {arg} out of "
                        f"range in {co.co_name!r}"
                    )
                return end - 2, consts[arg]
            if op == _OP_LOAD_SMALL_INT:
                return end - 2, arg
            if op == _OP_BUILD_MAP:
                cursor = end - 2
                pairs: list[tuple[object, object]] = []
                for _ in range(arg):
                    value_start, value = parse_attr_producer(cursor)
                    key_start, key = parse_attr_producer(value_start)
                    pairs.append((key, value))
                    cursor = key_start
                return cursor, dict(reversed(pairs))
            raise ValueError(
                f"Unsupported SET_FUNCTION_ATTRIBUTE producer opcode "
                f"{dis.opname[op]!r} in {co.co_name!r} before bytecode "
                f"offset {end}"
            )

        # Recurse into nested code objects first (identity-stable replace).
        changed_consts = False
        for i, const in enumerate(consts):
            if isinstance(const, types.CodeType):
                new_c = fold_one(const)
                if new_c is not const:
                    consts[i] = new_c
                    changed_consts = True

        i = 0
        n = len(code)
        while i + 5 < n:
            op0, a0 = code[i], code[i + 1]
            op1, _a1 = code[i + 2], code[i + 3]
            if op0 == _OP_LOAD_CONST and op1 == _OP_MAKE_FUNCTION:
                func_co = consts[a0] if a0 < len(consts) else None
                sfa_ops: list[tuple[int, int]] = []
                cursor = i + 4
                while cursor + 1 < n and code[cursor] == _OP_SET_FUNCTION_ATTRIBUTE:
                    flag = code[cursor + 1]
                    if flag not in (_SFA_FLAG_DEFAULTS, _SFA_FLAG_KWDEFAULTS):
                        raise ValueError(
                            f"SET_FUNCTION_ATTRIBUTE flag {flag} in {co.co_name!r} "
                            f"at offset {cursor}: only defaults (1) and "
                            "kwdefaults (2) supported"
                        )
                    sfa_ops.append((cursor, flag))
                    cursor += 2
                if not sfa_ops:
                    i += 2
                    continue
                if not isinstance(func_co, types.CodeType):
                    raise ValueError(
                        f"MAKE_FUNCTION target at const {a0} in {co.co_name!r} "
                        "is not a code object"
                    )
                producers: list[tuple[int, int, object]] = []
                producer_cursor = i
                for _sfa_off, _flag in sfa_ops:
                    start, value = parse_attr_producer(producer_cursor)
                    producers.append((start, producer_cursor, value))
                    producer_cursor = start

                for (sfa_off, flag), (start, end, value) in zip(sfa_ops, producers):
                    if flag == _SFA_FLAG_DEFAULTS:
                        if not isinstance(value, tuple):
                            raise ValueError(
                                f"defaults for {func_co.co_name!r} in {co.co_name!r} "
                                f"are {type(value).__name__}, expected tuple"
                            )
                        defaults_map[id(func_co)] = value
                    elif flag == _SFA_FLAG_KWDEFAULTS:
                        if not isinstance(value, dict):
                            raise ValueError(
                                f"kwdefaults for {func_co.co_name!r} in "
                                f"{co.co_name!r} are {type(value).__name__}, "
                                "expected dict"
                            )
                        bad_keys = [key for key in value if not isinstance(key, str)]
                        if bad_keys:
                            raise ValueError(
                                f"kwdefaults for {func_co.co_name!r} contain "
                                f"non-string keys: {bad_keys!r}"
                            )
                        kwdefaults_map[id(func_co)] = value
                    nop_span(start, end)
                    code[sfa_off] = _OP_NOP
                    code[sfa_off + 1] = 0
                i = cursor
                continue
            i += 2

        new_co = co
        if changed_consts or bytes(code) != co.co_code:
            new_co = co.replace(co_code=bytes(code), co_consts=tuple(consts))
            # Remap defaults_map keys if nested codes were replaced.
            # fold_one already keyed nested by their (possibly new) ids when
            # fold_one ran on them; the MAKE_FUNCTION target id is from the
            # consts list after nested rewrite, so id(func_co) is correct.
        return new_co

    return fold_one(module_code), defaults_map, kwdefaults_map


def _code_handles_by_name(
    module_code: types.CodeType, code_handles: dict[int, Tagged]
) -> dict[str, Tagged]:
    out: dict[str, Tagged] = {}
    for co in iter_code_objects(module_code):
        handle = code_handles.get(id(co))
        if handle is not None:
            out[co.co_name] = handle
    return out


def _seed_globals_pairs(
    heap: HeapImageBuilder,
    string_heap: StringHeapBuilder,
    seeds: SeedSpecs,
    code_by_name: dict[str, Tagged],
) -> list[tuple[Tagged, Tagged]]:
    """Allocate seeded TYPE/INSTANCE objects and return globals key/value pairs."""
    type_handles: dict[str, Tagged] = {}
    pairs: list[tuple[Tagged, Tagged]] = []

    methods_by_type: dict[str, list[SeedTypeMethodSpec]] = {}
    for m in seeds.type_methods:
        methods_by_type.setdefault(m.type_name, []).append(m)

    for spec in seeds.types:
        attr_pairs: list[tuple[Tagged, Tagged]] = []
        for attr_name, attr_val in spec.attrs:
            attr_pairs.append(
                (
                    tag_constant(attr_name, string_heap),
                    (TAG_INT, int_value(attr_val)),
                )
            )
        for mspec in methods_by_type.get(spec.name, []):
            handle = code_by_name.get(mspec.func_name)
            if handle is None:
                raise ValueError(
                    f"SEED_TYPE_METHOD {spec.name}.{mspec.attr_name}: "
                    f"function {mspec.func_name!r} not found among code objects"
                )
            attr_pairs.append(
                (tag_constant(mspec.attr_name, string_heap), handle)
            )
        n_keys = max(len(attr_pairs), 1)
        tp_dict = heap.alloc_dict(
            attr_pairs,
            slot_count=dict_min_slots(n_keys),
        )
        tp_name = tag_constant(spec.name, string_heap)
        tp_base: Tagged | None = None
        if spec.base_name is not None:
            tp_base = type_handles.get(spec.base_name)
            if tp_base is None:
                raise ValueError(
                    f"SEED_TYPE {spec.name!r} base={spec.base_name!r}: "
                    "declare the base SEED_TYPE earlier in the source"
                )
        handle = heap.alloc_type(tp_name, tp_dict=tp_dict, tp_base=tp_base)
        type_handles[spec.name] = handle
        pairs.append((tag_constant(spec.name, string_heap), handle))

    for mspec in seeds.type_methods:
        if mspec.type_name not in type_handles:
            raise ValueError(
                f"SEED_TYPE_METHOD references unknown type {mspec.type_name!r}; "
                "declare SEED_TYPE first"
            )

    for spec in seeds.instances:
        type_addr = 0
        if spec.type_name is not None:
            th = type_handles.get(spec.type_name)
            if th is None:
                raise ValueError(
                    f"SEED_INSTANCE {spec.name!r} references unknown type "
                    f"{spec.type_name!r}; declare SEED_TYPE first"
                )
            type_addr = th[1] & ((1 << 64) - 1)
        attr_pairs: list[tuple[Tagged, Tagged]] = []
        for attr_name, attr_val in spec.attrs:
            attr_pairs.append(
                (
                    tag_constant(attr_name, string_heap),
                    (TAG_INT, int_value(attr_val)),
                )
            )
        idict_slots = spec.slots
        if attr_pairs and idict_slots > 0 and len(attr_pairs) >= idict_slots:
            raise ValueError(
                f"SEED_INSTANCE {spec.name!r}: {len(attr_pairs)} attrs need "
                f"slots > {idict_slots}"
            )
        idict = heap.alloc_dict(attr_pairs, slot_count=idict_slots)
        handle = heap.alloc_instance(type_addr=type_addr, idict=idict)
        pairs.append((tag_constant(spec.name, string_heap), handle))

    return pairs


# (dict_key, source_stem, func_name) → pycore_firmware/builtins/{stem}.py
ROM_FIRMWARE_BUILTINS: tuple[tuple[str, str, str], ...] = (
    # Wave 1–2
    ("sum", "sum", "sum"),
    ("abs", "abs", "abs"),
    ("bool", "bool", "bool"),
    ("all", "all", "all"),
    ("any", "any", "any"),
    ("enumerate", "enumerate", "enumerate"),
    ("map", "map", "map"),
    ("zip", "zip", "zip"),
    # Wave 3A.1 — numeric / string / tuple
    ("divmod", "divmod", "divmod"),
    ("pow", "pow", "pow"),
    ("round", "round", "round"),
    ("bin", "bin", "bin"),
    ("hex", "hex", "hex"),
    ("oct", "oct", "oct"),
    ("tuple", "tuple", "tuple"),
    ("min", "min", "min"),
    # Wave 3A.2 — containers / iterators (LIST grow → excore)
    ("list", "list", "list"),
    ("dict", "dict", "dict"),
    ("reversed", "reversed", "reversed"),
    ("filter", "filter", "filter"),
    ("sorted", "sorted", "sorted"),
    # Wave 4B — attr protocol (needs LOAD_ATTR __dict__/__class__/__base__)
    ("hasattr", "hasattr", "hasattr"),
    ("getattr", "getattr", "getattr"),
    ("setattr", "setattr", "setattr"),
    ("delattr", "delattr", "delattr"),
    ("isinstance", "isinstance", "isinstance"),
    ("issubclass", "issubclass", "issubclass"),
    # Wave 4A — print(*args, sep=, end=) → _bi_print sink
    ("print", "print", "print"),
)

FIRMWARE_BUILTINS_DIR = (
    pathlib.Path(__file__).resolve().parents[2] / "pycore_firmware" / "builtins"
)


def _host_bi_print(x: object) -> None:
    """Host stand-in for native ``_bi_print`` / ``BI_PRINT`` (CONSOLE_TX)."""
    import sys

    if x is None:
        sys.stdout.write("None")
    elif x is True:
        sys.stdout.write("True")
    elif x is False:
        sys.stdout.write("False")
    else:
        sys.stdout.write(str(x))


def load_rom_firmware_callables() -> dict[str, object]:
    """Load ROM firmware bodies as host callables for golden / unit tests.

    Mirrors the boot-record builtins dict: every ``ROM_FIRMWARE_BUILTINS``
    entry plus a ``_bi_print`` stub so ``print`` can run on the host.
    Firmware semantics differ from CPython in places (e.g. ``reversed`` /
    ``filter`` return lists); host goldens must use these bodies.
    """
    out: dict[str, object] = {"_bi_print": _host_bi_print}
    for dict_key, stem, func_name in ROM_FIRMWARE_BUILTINS:
        path = FIRMWARE_BUILTINS_DIR / f"{stem}.py"
        if not path.is_file():
            raise FileNotFoundError(f"ROM firmware builtin source missing: {path}")
        ns: dict[str, object] = {
            "__name__": f"pycore_firmware.builtins.{stem}",
            "_bi_print": _host_bi_print,
            "len": len,
            "range": range,
        }
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        fn = ns.get(func_name)
        if not callable(fn):
            raise ValueError(
                f"firmware {path.name!r}: expected function {func_name!r}, "
                f"got {type(fn).__name__}"
            )
        out[dict_key] = fn
    return out


def seed_firmware_function(
    serializer: _ImageSerializer,
    source_path: pathlib.Path,
    func_name: str,
) -> Tagged:
    """Compile a firmware .py and serialize its named function as a CODE_OBJECT.

    Defaults are taken from the live function object (``__defaults__`` /
    ``__kwdefaults__``) and stored in the serializer maps for CALL arity fill
    — the same path used for user functions after ``fold_function_defaults``.
    """
    source_path = pathlib.Path(source_path)
    source_text = source_path.read_text(encoding="utf-8")
    module_code = compile(source_text, str(source_path), "exec")
    ns: dict[str, object] = {}
    exec(module_code, ns)
    func = ns.get(func_name)
    if not isinstance(func, types.FunctionType):
        raise ValueError(
            f"firmware {source_path.name!r}: expected function {func_name!r}, "
            f"got {type(func).__name__}"
        )
    co = func.__code__
    validate_code_tree(co)
    defaults = func.__defaults__
    if defaults:
        serializer.defaults_map[id(co)] = defaults
    kwdefaults = func.__kwdefaults__
    if kwdefaults:
        serializer.kwdefaults_map[id(co)] = dict(kwdefaults)
    return serializer.serialize_code(co)


def seed_rom_firmware_builtins(
    serializer: _ImageSerializer,
) -> list[tuple[Tagged, Tagged]]:
    """Return (name, CODE_OBJECT) pairs for every ROM_FIRMWARE_BUILTINS entry."""
    pairs: list[tuple[Tagged, Tagged]] = []
    for dict_key, stem, func_name in ROM_FIRMWARE_BUILTINS:
        path = FIRMWARE_BUILTINS_DIR / f"{stem}.py"
        if not path.is_file():
            raise FileNotFoundError(f"ROM firmware builtin source missing: {path}")
        handle = seed_firmware_function(serializer, path, func_name)
        pairs.append(
            (tag_constant(dict_key, serializer.string_heap), handle)
        )
    return pairs


def build_builtins_dict(serializer: _ImageSerializer) -> Tagged:
    """Allocate the module builtins dict for the boot-record pair-2 slot.

    Entries:
      bytearray / max / len / _bi_print / range / set → OBK_BUILTIN (bound_self=NULL)
      int → OBK_TYPE whose tp_dict holds from_bytes / to_bytes builtins
      StopIteration → leaf OBK_TYPE (tp_base = None / 0) for RAISE / except
      ROM_FIRMWARE_BUILTINS (incl. print) → CODE_OBJECT handles

    Also writes the StopIteration handle to the exc-arena boot sidecar so
    ``S_BOOT`` can latch ``iter_exhaust_type_r`` without a dict probe.
    """
    heap = serializer.heap
    string_heap = serializer.string_heap
    from_bytes = heap.alloc_builtin(BI_FROM_BYTES)
    to_bytes = heap.alloc_builtin(BI_TO_BYTES)
    int_tp_dict = heap.alloc_dict(
        [
            (tag_constant("from_bytes", string_heap), from_bytes),
            (tag_constant("to_bytes", string_heap), to_bytes),
        ],
        slot_count=dict_min_slots(2),
    )
    int_type = heap.alloc_type(
        tag_constant("int", string_heap),
        tp_dict=int_tp_dict,
    )
    stop_iteration = heap.alloc_type(tag_constant("StopIteration", string_heap))
    heap.write_iter_exhaust_type(stop_iteration)
    pairs: list[tuple[Tagged, Tagged]] = [
        (tag_constant("bytearray", string_heap), heap.alloc_builtin(BI_BYTEARRAY)),
        (tag_constant("max", string_heap), heap.alloc_builtin(BI_MAX)),
        (tag_constant("len", string_heap), heap.alloc_builtin(BI_LEN)),
        # Native console sink; public print is the ROM CODE_OBJECT below.
        (tag_constant("_bi_print", string_heap), heap.alloc_builtin(BI_PRINT)),
        (tag_constant("range", string_heap), heap.alloc_builtin(BI_RANGE)),
        (tag_constant("set", string_heap), heap.alloc_builtin(BI_SET)),
        (tag_constant("int", string_heap), int_type),
        (tag_constant("StopIteration", string_heap), stop_iteration),
    ]
    pairs.extend(seed_rom_firmware_builtins(serializer))
    return heap.alloc_dict(pairs, slot_count=dict_min_slots(len(pairs)))


def build_image_from_code(
    module_code: types.CodeType,
    *,
    seeds: SeedSpecs | None = None,
    defaults_map: dict[int, tuple] | None = None,
    kwdefaults_map: dict[int, dict] | None = None,
    class_specs: list[ClassBuildSpec] | None = None,
) -> ImageBuildResult:
    require_python_3_14()
    validate_code_tree(module_code)

    seeds = seeds or SeedSpecs()
    class_specs = class_specs or []
    stored_names = count_global_store_names(module_code)
    # Pre-seeded globals keys plus room for runtime STORE_NAME / STORE_GLOBAL.
    n_for_slots = len(stored_names | seeds.global_names)
    globals_slot_count = dict_slot_count_for_stores(n_for_slots)

    serializer = _ImageSerializer(
        defaults_map=defaults_map,
        kwdefaults_map=kwdefaults_map,
    )
    # Method codes + OBK_TYPE must exist before module consts resolve type refs.
    serializer.alloc_class_types(class_specs)
    # Serialize module so SEED_TYPE_METHOD can resolve CODE_OBJECT handles.
    module_handle = serializer.serialize_code(module_code)
    code_by_name = _code_handles_by_name(module_code, serializer.code_handles)
    seed_pairs = _seed_globals_pairs(
        serializer.heap, serializer.string_heap, seeds, code_by_name
    )
    if seed_pairs:
        if len(seed_pairs) >= globals_slot_count:
            globals_slot_count = dict_slot_count_for_stores(len(seed_pairs) + 1)
        globals_dict = serializer.heap.alloc_dict(
            seed_pairs, slot_count=globals_slot_count
        )
    else:
        globals_dict = serializer.heap.alloc_empty_globals(len(stored_names))
        globals_slot_count = dict_slot_count_for_stores(len(stored_names))

    # After module serialize so firmware bytecode appends to the same imem pool.
    builtins_dict = build_builtins_dict(serializer)
    serializer.heap.write_boot_record(module_handle, globals_dict, builtins_dict)

    return ImageBuildResult(
        module_code=module_handle,
        globals_dict=globals_dict,
        builtins_dict=builtins_dict,
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


# Hand-assemble MAP_ADD sequences (compile() only emits MAP_ADD in dict
# comprehensions, which also emit RERAISE cleanup that hardware defers). Pragma:
#   # pycore-inject: MAP_ADD_SEQ <func> <k0> <v0> <k1> <v1> ...
# Builds BUILD_MAP 0 + (LOAD_FAST d; key; value; MAP_ADD 1; POP_TOP)* and
# returns the sum of the stored values (each read back with d[key]).
_INJECT_MAP_ADD_PREFIX = "# pycore-inject: MAP_ADD_SEQ "
_OP_MAP_ADD = _OM["MAP_ADD"]
_OP_BUILD_MAP = _OM["BUILD_MAP"]
_OP_POP_TOP = _OM["POP_TOP"]
_NB_SUBSCR = next(
    i for i, (n, _s) in enumerate(_opcode_module._nb_ops) if n == "NB_SUBSCR"
)


def parse_map_add_seq_pragmas(
    source_text: str,
) -> list[tuple[str, list[tuple[int, int]]]]:
    """Return ``(func, [(key, value), ...])`` for each MAP_ADD_SEQ pragma."""
    out: list[tuple[str, list[tuple[int, int]]]] = []
    for line in source_text.splitlines():
        stripped = line.strip()
        if not stripped.startswith(_INJECT_MAP_ADD_PREFIX):
            continue
        rest = stripped[len(_INJECT_MAP_ADD_PREFIX):].strip().split()
        if len(rest) < 3 or (len(rest) - 1) % 2 != 0:
            raise ValueError(
                "pycore-inject MAP_ADD_SEQ expects '<func> <k> <v> ...' pairs, "
                f"got {stripped!r}"
            )
        func = rest[0]
        nums = [int(tok) for tok in rest[1:]]
        pairs = list(zip(nums[0::2], nums[1::2]))
        out.append((func, pairs))
    return out


def _build_map_add_seq_code(
    template: types.CodeType, pairs: list[tuple[int, int]]
) -> types.CodeType:
    """Replace ``template`` bytecode with BUILD_MAP0 + MAP_ADDs + value sum."""
    code = bytearray()
    _binary_caches = sum(_opcode_module._cache_format["BINARY_OP"].values())

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
    emit(_OP_STORE_FAST, 0)  # d
    for k, v in pairs:
        if not (0 <= k <= 255 and 0 <= v <= 255):
            raise ValueError(f"MAP_ADD_SEQ key/value must be 0..255, got {k},{v}")
        emit(_OP_LOAD_FAST, 0)      # d
        emit(_OP_LOAD_SMALL_INT, k)  # key
        emit(_OP_LOAD_SMALL_INT, v)  # value
        emit(_OP_MAP_ADD, 1)         # d[key] = value; leaves d on stack
        emit(_OP_POP_TOP, 0)
    # acc = 0; acc += d[k] for each key
    emit(_OP_LOAD_SMALL_INT, 0)
    for k, _v in pairs:
        emit(_OP_LOAD_FAST, 0)
        emit(_OP_LOAD_SMALL_INT, k)
        emit(_OP_BINARY_OP, _NB_SUBSCR)
        emit_caches(_binary_caches)
        emit(_OP_BINARY_OP, 0)  # +
        emit_caches(_binary_caches)
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
    for func_name, pairs in parse_map_add_seq_pragmas(source_text):
        target = _find_code_by_name(result, func_name)
        if target is None:
            raise ValueError(
                f"pycore-inject MAP_ADD_SEQ target {func_name!r} not found"
            )
        rewritten = _build_map_add_seq_code(target, pairs)
        result = _replace_code_by_name(result, func_name, rewritten)
    return result


def _code_has_load_build_class(co: types.CodeType) -> bool:
    for ins in iter_raw_instructions(co):
        if ins.opname == "LOAD_BUILD_CLASS":
            return True
    return False


def _reject_nested_load_build_class(module_code: types.CodeType) -> None:
    """Reject class creation inside functions / nested code objects."""
    for const in module_code.co_consts:
        if not isinstance(const, types.CodeType):
            continue
        for co in iter_code_objects(const):
            if _code_has_load_build_class(co):
                raise ValueError(
                    f"class creation inside function/code {co.co_name!r} is not "
                    "supported; only module-level classes can be folded at "
                    "image-build time"
                )


def _module_level_class_nodes(source_text: str) -> dict[str, ast.ClassDef]:
    tree = ast.parse(source_text)
    out: dict[str, ast.ClassDef] = {}
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            out[node.name] = node
    return out


def _validate_class_ast(node: ast.ClassDef) -> None:
    if node.bases:
        raise ValueError(
            f"class {node.name!r}: bases are not supported (only implicit object); "
            "got bases in source"
        )
    if node.keywords:
        raise ValueError(
            f"class {node.name!r}: metaclass/keywords are not supported"
        )
    if node.decorator_list:
        raise ValueError(
            f"class {node.name!r}: class decorators are not supported"
        )
    for stmt in node.body:
        if isinstance(stmt, ast.FunctionDef) or isinstance(stmt, ast.AsyncFunctionDef):
            if isinstance(stmt, ast.AsyncFunctionDef):
                raise ValueError(
                    f"class {node.name!r}: async methods are not supported "
                    f"({stmt.name!r})"
                )
            for dec in stmt.decorator_list:
                if isinstance(dec, ast.Name) and dec.id == "staticmethod":
                    continue
                if isinstance(dec, ast.Name) and dec.id == "classmethod":
                    raise ValueError(
                        f"class {node.name!r}: @classmethod is not supported "
                        f"({stmt.name!r})"
                    )
                raise ValueError(
                    f"class {node.name!r}: unsupported decorator on method "
                    f"{stmt.name!r} (only @staticmethod is allowed)"
                )
        elif isinstance(stmt, ast.Assign):
            for t in stmt.targets:
                if isinstance(t, ast.Name) and t.id == "__slots__":
                    raise ValueError(
                        f"class {node.name!r}: __slots__ is not supported"
                    )
        elif isinstance(stmt, ast.AnnAssign):
            if isinstance(stmt.target, ast.Name) and stmt.target.id == "__slots__":
                raise ValueError(
                    f"class {node.name!r}: __slots__ is not supported"
                )
        elif isinstance(stmt, ast.Pass):
            continue
        elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
            continue  # docstring
        else:
            # Allow other simple statements only if host-exec classification
            # accepts the resulting type dict; still reject obvious bad forms.
            if isinstance(stmt, (ast.ClassDef, ast.With, ast.For, ast.While,
                                 ast.If, ast.Try, ast.Import, ast.ImportFrom)):
                raise ValueError(
                    f"class {node.name!r}: unsupported statement "
                    f"{type(stmt).__name__} in class body"
                )


_SKIP_TYPE_ATTRS = frozenset({
    "__module__",
    "__dict__",
    "__weakref__",
    "__doc__",
    "__qualname__",
    "__firstlineno__",
    "__static_attributes__",
    "__classdictcell__",
})


def _class_build_spec_from_type(typ: type) -> ClassBuildSpec:
    name = typ.__name__
    if typ.__bases__ != (object,):
        raise ValueError(
            f"class {name!r}: bases other than implicit object are not "
            f"supported (bases={typ.__bases__!r})"
        )
    if typ.__dict__.get("__slots__") is not None or "__slots__" in typ.__dict__:
        raise ValueError(f"class {name!r}: __slots__ is not supported")

    methods: dict[str, types.CodeType] = {}
    static_methods: dict[str, types.CodeType] = {}
    constants: dict[str, object] = {}
    method_defaults: dict[int, tuple] = {}
    method_kwdefaults: dict[int, dict] = {}

    for attr_name, value in typ.__dict__.items():
        if attr_name in _SKIP_TYPE_ATTRS:
            continue
        if attr_name == "__slots__":
            raise ValueError(f"class {name!r}: __slots__ is not supported")
        if isinstance(value, classmethod):
            raise ValueError(
                f"class {name!r}: @classmethod is not supported ({attr_name!r})"
            )
        if isinstance(value, staticmethod):
            func = value.__func__
            if not isinstance(func, types.FunctionType):
                raise ValueError(
                    f"class {name!r}: staticmethod {attr_name!r} is not a "
                    "plain function"
                )
            static_methods[attr_name] = func.__code__
            if func.__defaults__:
                method_defaults[id(func.__code__)] = func.__defaults__
            if func.__kwdefaults__:
                method_kwdefaults[id(func.__code__)] = dict(func.__kwdefaults__)
            continue
        if isinstance(value, types.FunctionType):
            methods[attr_name] = value.__code__
            if value.__defaults__:
                method_defaults[id(value.__code__)] = value.__defaults__
            if value.__kwdefaults__:
                method_kwdefaults[id(value.__code__)] = dict(value.__kwdefaults__)
            continue
        if value is None or isinstance(value, (bool, int, str)):
            constants[attr_name] = value
            continue
        raise ValueError(
            f"class {name!r}: unsupported class body attribute "
            f"{attr_name!r} of type {type(value).__name__} "
            "(allowed: methods, @staticmethod, int/bool/str/None constants)"
        )

    return ClassBuildSpec(
        name=name,
        methods=methods,
        static_methods=static_methods,
        constants=constants,
        method_defaults=method_defaults,
        method_kwdefaults=method_kwdefaults,
    )


def _host_exec_class(node: ast.ClassDef, source_text: str) -> type:
    segment = ast.get_source_segment(source_text, node)
    if segment is None:
        # Fallback: unparse the ClassDef.
        segment = ast.unparse(node)
    ns: dict[str, object] = {"__name__": "__pycore_class__"}
    exec(compile(segment, f"<class:{node.name}>", "exec"), ns)
    typ = ns.get(node.name)
    if not isinstance(typ, type):
        raise ValueError(
            f"class {node.name!r}: host exec did not produce a type object"
        )
    return typ


def _encode_const_index(index: int) -> list[tuple[int, int]]:
    """Return ``(opcode, arg8)`` units for ``LOAD_CONST index`` (+ EXTENDED_ARG)."""
    if index < 0:
        raise ValueError(f"negative const index {index}")
    units: list[tuple[int, int]] = []
    if index > 0xFFFFFF:
        raise ValueError(f"const index {index} exceeds 24-bit EXTENDED_ARG range")
    if index > 0xFFFF:
        units.append((OP_EXTENDED_ARG, (index >> 16) & 0xFF))
        units.append((OP_EXTENDED_ARG, (index >> 8) & 0xFF))
        units.append((_OP_LOAD_CONST, index & 0xFF))
    elif index > 0xFF:
        units.append((OP_EXTENDED_ARG, (index >> 8) & 0xFF))
        units.append((_OP_LOAD_CONST, index & 0xFF))
    else:
        units.append((_OP_LOAD_CONST, index))
    return units


def _match_class_creation_span(
    code: bytes, consts: tuple, names: tuple[str, ...]
) -> list[tuple[int, int, str, int]]:
    """Find module-level class-creation spans.

    Returns list of ``(start, end_exclusive, class_name, body_const_index)``
    where offsets are byte offsets into ``co_code``. Pattern (CPython 3.14)::

        LOAD_BUILD_CLASS
        PUSH_NULL
        LOAD_CONST <body code>
        MAKE_FUNCTION
        LOAD_CONST <'Name'>
        CALL 2
        CACHE*
        STORE_NAME Name
    """
    matches: list[tuple[int, int, str, int]] = []
    i = 0
    n = len(code)
    while i + 11 < n:
        if code[i] != _OP_LOAD_BUILD_CLASS:
            i += 2
            continue
        # Fixed prefix through CALL (6 units = 12 bytes) before caches.
        if i + 12 > n:
            raise ValueError(
                "truncated LOAD_BUILD_CLASS class-creation sequence at "
                f"bytecode offset {i}"
            )
        if code[i + 2] != _OP_PUSH_NULL:
            raise ValueError(
                f"LOAD_BUILD_CLASS at offset {i}: expected PUSH_NULL "
                "(CPython 3.14 class idiom); dynamic class creation is deferred"
            )
        if code[i + 4] != _OP_LOAD_CONST:
            raise ValueError(
                f"LOAD_BUILD_CLASS at offset {i}: expected LOAD_CONST body"
            )
        body_idx = code[i + 5]
        if code[i + 6] != _OP_MAKE_FUNCTION:
            raise ValueError(
                f"LOAD_BUILD_CLASS at offset {i}: expected MAKE_FUNCTION"
            )
        if code[i + 8] != _OP_LOAD_CONST:
            raise ValueError(
                f"LOAD_BUILD_CLASS at offset {i}: expected LOAD_CONST name"
            )
        name_idx = code[i + 9]
        if code[i + 10] != _OP_CALL:
            # Bases/keywords insert LOAD_NAME / KW_NAMES before CALL.
            raise ValueError(
                f"class creation at offset {i}: bases or keywords present "
                "(expected CALL 2 immediately after class name); only "
                "no-base classes are supported"
            )
        argc = code[i + 11]
        if argc != 2:
            raise ValueError(
                f"class creation at offset {i}: CALL argc={argc} (bases or "
                "keywords present); only no-base classes (CALL 2) are supported"
            )
        body = consts[body_idx] if body_idx < len(consts) else None
        name_const = consts[name_idx] if name_idx < len(consts) else None
        if not isinstance(body, types.CodeType):
            raise ValueError(
                f"class creation at offset {i}: body const is not a code object"
            )
        if not isinstance(name_const, str):
            raise ValueError(
                f"class creation at offset {i}: name const is not a string"
            )
        # Skip CALL inline caches.
        j = i + 12
        while j < n and code[j] == OP_CACHE:
            j += 2
        if j + 1 >= n or code[j] != _OP_STORE_NAME:
            raise ValueError(
                f"class creation at offset {i}: expected STORE_NAME after CALL"
            )
        store_namei = code[j + 1]
        if store_namei >= len(names) or names[store_namei] != name_const:
            raise ValueError(
                f"class creation at offset {i}: STORE_NAME target does not "
                f"match class name {name_const!r}"
            )
        end = j + 2
        matches.append((i, end, name_const, body_idx))
        i = end
    return matches


def fold_module_classes(
    module_code: types.CodeType,
    source_text: str,
) -> tuple[types.CodeType, list[ClassBuildSpec]]:
    """Fold module-level ``class`` idioms into ``_PyCoreTypeRef`` + STORE_NAME.

    Rewrites each matched span in place with NOP padding (never compact) so
    branch offsets stay valid. Class body code consts are replaced with
    ``None`` so unsupported body opcodes are not validated/serialized.
    """
    _reject_nested_load_build_class(module_code)

    if not _code_has_load_build_class(module_code):
        return module_code, []

    ast_classes = _module_level_class_nodes(source_text)
    matches = _match_class_creation_span(
        module_code.co_code, module_code.co_consts, module_code.co_names
    )
    if not matches:
        # LOAD_BUILD_CLASS present but no match — leave for validate/DEFERRED.
        return module_code, []

    code = bytearray(module_code.co_code)
    consts: list[object] = list(module_code.co_consts)
    specs: list[ClassBuildSpec] = []
    seen_names: set[str] = set()

    for start, end, class_name, body_idx in matches:
        if class_name in seen_names:
            raise ValueError(
                f"duplicate module-level class {class_name!r} is not supported"
            )
        seen_names.add(class_name)
        node = ast_classes.get(class_name)
        if node is None:
            raise ValueError(
                f"class {class_name!r}: found in bytecode but not as a "
                "module-level class statement in source"
            )
        _validate_class_ast(node)
        typ = _host_exec_class(node, source_text)
        if typ.__name__ != class_name:
            raise ValueError(
                f"class {class_name!r}: host type name mismatch {typ.__name__!r}"
            )
        spec = _class_build_spec_from_type(typ)
        specs.append(spec)

        # Replace body code const with None (drop LOAD_LOCALS / MAKE_CELL etc.).
        consts[body_idx] = None

        ref = _PyCoreTypeRef(class_name)
        ref_index = len(consts)
        consts.append(ref)

        load_units = _encode_const_index(ref_index)
        # STORE_NAME is the last unit of the span.
        store_off = end - 2
        store_namei = code[store_off + 1]
        span_units = (end - start) // 2
        need_units = len(load_units) + 1  # LOAD* + STORE_NAME
        if need_units > span_units:
            raise ValueError(
                f"class {class_name!r}: rewritten LOAD_CONST/STORE_NAME needs "
                f"{need_units} units but span is only {span_units}"
            )
        # Write LOAD_CONST (+ EXTENDED_ARG) then STORE_NAME, NOP-pad the rest.
        cursor = start
        for op, arg8 in load_units:
            code[cursor] = op
            code[cursor + 1] = arg8
            cursor += 2
        code[cursor] = _OP_STORE_NAME
        code[cursor + 1] = store_namei
        cursor += 2
        while cursor < end:
            code[cursor] = _OP_NOP
            code[cursor + 1] = 0
            cursor += 2

    new_module = module_code.replace(
        co_code=bytes(code), co_consts=tuple(consts)
    )
    return new_module, specs


def build_image_from_source_text(source_text: str, filename: str) -> ImageBuildResult:
    seeds = parse_seed_pragmas(source_text)
    module_code = compile(source_text, filename, "exec")
    module_code = apply_lfac_injects(module_code, source_text)
    module_code = apply_set_add_seq_injects(module_code, source_text)
    module_code = apply_map_add_seq_injects(module_code, source_text)
    module_code, class_specs = fold_module_classes(module_code, source_text)
    module_code, defaults_map, kwdefaults_map = fold_function_defaults(module_code)
    for spec in class_specs:
        for co_id, defaults in spec.method_defaults.items():
            defaults_map[co_id] = defaults
        for co_id, kwdefaults in spec.method_kwdefaults.items():
            kwdefaults_map[co_id] = kwdefaults
    return build_image_from_code(
        module_code,
        seeds=seeds,
        defaults_map=defaults_map,
        kwdefaults_map=kwdefaults_map,
        class_specs=class_specs,
    )


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
    parser.add_argument(
        "--expected-tag",
        type=int,
        default=None,
        help="Optional EXPECTED_TAG for image.meta (skips host execution)",
    )
    parser.add_argument(
        "--expected-value",
        type=int,
        default=None,
        help="Optional EXPECTED_VALUE for image.meta (skips host execution)",
    )
    args = parser.parse_args()

    require_python_3_14()
    result = build_image_from_source(pathlib.Path(args.source))
    write_image_outputs(
        result,
        program_hex=pathlib.Path(args.program_hex),
        dmem_hex=pathlib.Path(args.dmem_hex),
        string_hex=pathlib.Path(args.string_hex),
        meta=pathlib.Path(args.meta),
        expected_tag=args.expected_tag,
        expected_value=args.expected_value,
    )


if __name__ == "__main__":
    main()
