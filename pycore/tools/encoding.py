"""Shared tagged-value encoding for PyCore tooling.

Used by preprocess.py (legacy single-function path) and image_from_source.py
(primary module-image path). Tag constants mirror pycore/rtl/pycore_defs.svh.
"""

from __future__ import annotations

import struct
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    pass

# Mirror the primary tag map in pycore/rtl/pycore_defs.svh.
TAG_CONTROL = 0b0000
TAG_INT = 0b0001
TAG_FLOAT = 0b0010
TAG_COMPLEX = 0b0011
TAG_BOOL = 0b0100
TAG_ITER = 0b0101
TAG_TUPLE = 0b0110
TAG_SHORT_STR = 0b0111
TAG_LONG_STR = 0b1000
TAG_MUT_COLLEC = 0b1001
TAG_OBJECT = 0b1010
TAG_RANGE = 0b1011
TAG_BYTES = 0b1100
TAG_CODE_OBJECT = 0b1101
TAG_TOMBSTONE = 0b1110
TAG_FROZENSET = 0b1111

# Migration aliases retained by RTL and legacy iterator/preprocess paths.
TAG_UNINIT = TAG_CONTROL
TAG_UNINITIALIZED = TAG_UNINIT
TAG_PTR = TAG_ITER

# CONTROL secondary ids in value[3:0].
CTL_UNINIT = 0
CTL_NONE = 1
CTL_NULL = 2

# MUT_COLLEC secondary kinds in value[127:124].
# Contamination bit lives in value[123]: set when the collection has ever
# contained a TAG_OBJECT element (dicts: OBJECT keys only). Used to keep
# bulk update/merge hashing on pycore when excore cannot hash OBJECTs.
# FROZENSET (when live) uses the same value[123] convention.
MUT_LIST = 1
MUT_DICT = 2
MUT_SET = 3
MUT_BYTEARRAY = 4
MUT_DEQUE = 5
MUT_CONTAMINATED_BIT = 123

SHORT_STR_MAX_BYTES = 15
SHORT_STR_SIZE_SHIFT = 124
SHORT_STR_DATA_SHIFT = 4
STRING_MEM_BYTES = 65536
STRING_RUNTIME_BASE = 16384

VAL_WIDTH = 128
VAL_MASK = (1 << VAL_WIDTH) - 1
TAG_WIDTH = 4
ENTRY_HEX_DIGITS = (TAG_WIDTH + VAL_WIDTH + 3) // 4  # ceil(132/4) == 33

IMEM_SLOT_BITS = 64
IMEM_SLOT_HEX_DIGITS = IMEM_SLOT_BITS // 4  # 16

# Boot record occupies [BOOT_RECORD_ADDR, BOOT_RECORD_ADDR+BOOT_RECORD_BYTES).
# HEAP_BASE is the first byte after that record so static/bump allocations never
# overlap the three boot pairs (code / globals / builtins).
BOOT_RECORD_ADDR = 0x03E0
BOOT_RECORD_BYTES = 96
HEAP_BASE = BOOT_RECORD_ADDR + BOOT_RECORD_BYTES  # 0x0440
# Mirror PYCORE_HEAP_LIMIT in pycore_defs.svh (below exc-info arena at 0x1B000).
HEAP_LIMIT = 0x1B000
# Exc-info stack arena (§5.5); last tagged entry holds the boot StopIteration latch.
EXC_STACK_BASE = 0x1B000
EXC_STACK_BYTES = 0x1000
ITER_EXHAUST_TYPE_ADDR = EXC_STACK_BASE + EXC_STACK_BYTES - 32  # 0x1BFE0

# LIST element buffer stride (bytes); mirror pycore list layout (32B/element).
LIST_ELEMENT_BYTES = 32
# Minimum / maximum word capacities for allocator_list (_zeros needs % 16 == 0).
# Min must cover CHUNKSIZE (64) + prologue for the CS:APP free-list workload.
ALLOCATOR_LIST_CAPACITY_MIN = 128
ALLOCATOR_LIST_CAPACITY_MAX = 4096


def allocator_list_capacity(available_bytes: int) -> int:
    """Safe list-word capacity for ``allocator_list`` under a live heap budget.

    Callers should pass ``HEAP_LIMIT - HEAP_INIT_PTR`` (runtime bump headroom
    after the static image).  Each word becomes one LIST cell (32 B); LIST_EXTEND
    grow may briefly need ~2× the final buffer, and we keep additional slack so
    the Allocator object and temporaries still fit.  Result is a multiple of 16
    for ``_zeros``.
    """
    if available_bytes <= 0:
        return ALLOCATOR_LIST_CAPACITY_MIN
    # 32 B/cell × 4 ≈ cell + grow peak + object/slack.
    words = available_bytes // (LIST_ELEMENT_BYTES * 4)
    words = (words // 16) * 16
    if words < ALLOCATOR_LIST_CAPACITY_MIN:
        return ALLOCATOR_LIST_CAPACITY_MIN
    if words > ALLOCATOR_LIST_CAPACITY_MAX:
        return ALLOCATOR_LIST_CAPACITY_MAX
    return words

# Code-object field indices (tuple-element convention at code addr).
CODE_FIELD_ENTRY_SLOT = 0
CODE_FIELD_CO_CONSTS = 1
CODE_FIELD_CO_NAMES = 2
CODE_FIELD_METADATA = 3
CODE_FIELD_CO_DEFAULTS = 4
CODE_FIELD_CO_VARNAMES = 5
CODE_FIELD_CO_KWDEFAULTS = 6
CODE_FIELD_CO_EXCEPTIONTABLE = 7
CODE_OBJECT_NFIELDS = 8
CODE_OBJECT_BYTES = CODE_OBJECT_NFIELDS * 32  # 256

# General OBJECT kinds under TAG_OBJECT (mirror PY_OBK_* in pycore_defs.svh).
OBK_INSTANCE = 1
OBK_TYPE = 2
OBK_BOUND_METHOD = 3
OBK_BUILTIN = 4
OBK_BYTEARRAY = 5
OBK_EXCEPTION = 6

# OBK_TYPE ob_flags bit 0: seeded exception type (CALL → OBK_EXCEPTION, Track 2).
OB_FLAG_EXC_TYPE = 1
# OBK_TYPE ob_flags bit 1: seeded `int` type (CALL converts, not INSTANCE).
OB_FLAG_INT_TYPE = 2
# OBK_TYPE ob_flags bit 2: seeded `str` type (CALL stringifies, not INSTANCE).
OB_FLAG_STR_TYPE = 4

# Builtin ids under OBK_BUILTIN (mirror PY_BI_* in pycore_defs.svh).
BI_STATICMETHOD = 0
BI_BYTEARRAY = 1
BI_FROM_BYTES = 2
BI_TO_BYTES = 3
BI_MAX = 4
BI_LIST_APPEND = 5
BI_PRINT = 6
BI_LEN = 7
BI_RANGE = 8
BI_SET = 9
BI_ORD = 10
BI_CHR = 11
BI_HEAP_MARK = 12
BI_HEAP_RELEASE = 13
BI_CODE_MARK = 14
BI_CODE_RELEASE = 15
BI_EXEC_GLOBALS = 16

# Code address space (mirror pycore_defs.svh PYCORE_CODE_RAM_*).
# The ROM holds IMEM_BLOCK_COUNT * 4096 / 8 slots; code RAM starts right after.
CODE_RAM_SLOT_BASE = 0x2000
CODE_RAM_SLOTS = 0x8000
CODE_RAM_SLOT_LIMIT = CODE_RAM_SLOT_BASE + CODE_RAM_SLOTS
CODE_RAM_BYTE_BASE = CODE_RAM_SLOT_BASE << 3

OBJ_HDR_BYTES = 32
OBJ_INSTANCE_BYTES = 64
OBJ_TYPE_BYTES = 128
OBJ_BOUND_METHOD_BYTES = 96
OBJ_BUILTIN_BYTES = 96
OBJ_BYTEARRAY_BYTES = 128
OBJ_EXCEPTION_BYTES = 96


def pack_ob_head(kind: int, flags: int = 0, type_addr: int = 0) -> int:
    """Pack ob_head: [127:96]=kind, [95:64]=flags, [63:0]=type_addr."""
    return (
        ((kind & 0xFFFFFFFF) << 96)
        | ((flags & 0xFFFFFFFF) << 64)
        | (type_addr & ((1 << 64) - 1))
    )


def ob_kind(head: int) -> int:
    return (head >> 96) & 0xFFFFFFFF


def ob_flags(head: int) -> int:
    return (head >> 64) & 0xFFFFFFFF


def ob_type(head: int) -> int:
    return head & ((1 << 64) - 1)


def obj_field_val_addr(obj: int, i: int) -> int:
    """Byte address of field *i* value (header occupies stride index 0)."""
    return obj + (i + 1) * 32


def obj_field_tag_addr(obj: int, i: int) -> int:
    return obj_field_val_addr(obj, i) + 16


def float_bits(value: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", value))[0]


def make_control(ctl: int) -> tuple[int, int]:
    """Return a CONTROL entry with the secondary id in value[3:0]."""
    return TAG_CONTROL, ctl & 0xF


def make_uninit() -> tuple[int, int]:
    return make_control(CTL_UNINIT)


def make_none() -> tuple[int, int]:
    return make_control(CTL_NONE)


def make_null() -> tuple[int, int]:
    return make_control(CTL_NULL)


UNINIT_ENTRY = make_uninit()
NONE_ENTRY = make_none()
NULL_ENTRY = make_null()


def make_mut(kind: int, addr: int, contaminated: bool = False) -> tuple[int, int]:
    """Return a MUT_COLLEC handle: kind[127:124], contam[123], addr[63:0]."""
    value = ((kind & 0xF) << 124) | (addr & ((1 << 64) - 1))
    if contaminated:
        value |= 1 << MUT_CONTAMINATED_BIT
    return TAG_MUT_COLLEC, value


def make_list(addr: int, contaminated: bool = False) -> tuple[int, int]:
    return make_mut(MUT_LIST, addr, contaminated)


def make_dict(addr: int, contaminated: bool = False) -> tuple[int, int]:
    return make_mut(MUT_DICT, addr, contaminated)


def make_set(addr: int, contaminated: bool = False) -> tuple[int, int]:
    return make_mut(MUT_SET, addr, contaminated)


def make_bytearray(addr: int, contaminated: bool = False) -> tuple[int, int]:
    return make_mut(MUT_BYTEARRAY, addr, contaminated)


def mut_kind(value: int) -> int:
    return (value >> 124) & 0xF


def mut_contaminated(value: int) -> bool:
    return bool((value >> MUT_CONTAMINATED_BIT) & 1)


def mut_addr(value: int) -> int:
    return value & ((1 << 64) - 1)


def mut_with_contam(value: int, contaminated: bool = True) -> int:
    """Return MUT_COLLEC value with contamination bit set or cleared."""
    if contaminated:
        return value | (1 << MUT_CONTAMINATED_BIT)
    return value & ~(1 << MUT_CONTAMINATED_BIT)


def is_mut_kind(entry: tuple[int, int], kind: int) -> bool:
    return entry[0] == TAG_MUT_COLLEC and mut_kind(entry[1]) == (kind & 0xF)


def make_complex(real: float, imag: float = 0) -> tuple[int, int]:
    """Encode complex(real, imag) as two IEEE754 binary64 bit patterns."""
    return TAG_COMPLEX, (float_bits(imag) << 64) | float_bits(real)


I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1


def range_fits_inline(value: range) -> bool:
    return all(I32_MIN <= part <= I32_MAX for part in (
        value.start, value.stop, value.step
    ))


def make_range_inline(start: int, stop: int, step: int = 1) -> tuple[int, int]:
    """Encode a RANGE inline as signed i32 start/stop/step in value[95:0]."""
    if not all(I32_MIN <= part <= I32_MAX for part in (start, stop, step)):
        raise ValueError("inline range start/stop/step must fit signed i32")
    if step == 0:
        raise ValueError("range() arg 3 must not be zero")
    value = (
        ((start & 0xFFFF_FFFF) << 64)
        | ((stop & 0xFFFF_FFFF) << 32)
        | (step & 0xFFFF_FFFF)
    )
    return TAG_RANGE, value


def make_range_tuple(addr: int) -> tuple[int, int]:
    """Encode a RANGE whose start/stop/step tuple lives at a heap address."""
    return TAG_RANGE, (1 << 127) | (addr & ((1 << 64) - 1))


def encode_short_string(data: bytes) -> int:
    """Encode a ≤15-byte UTF-8 string into the SHORT_STR value field."""
    if len(data) > SHORT_STR_MAX_BYTES:
        raise ValueError("short string max 15 bytes")
    payload = 0
    for idx, byte in enumerate(data):
        shift = SHORT_STR_DATA_SHIFT + (SHORT_STR_MAX_BYTES - 1 - idx) * 8
        payload |= int(byte) << shift
    payload |= (len(data) & 0xF) << SHORT_STR_SIZE_SHIFT
    return payload


# Alias used by heap_image.py
encode_short_str = encode_short_string


def int_value(n: int) -> int:
    return n & VAL_MASK


def format_imem_slot(opcode: int, arg: int = 0) -> str:
    """One 8-byte imem slot: bits[39:8]=arg, bits[7:0]=opcode."""
    word = ((arg & 0xFFFFFFFF) << 8) | (opcode & 0xFF)
    return f"{word:0{IMEM_SLOT_HEX_DIGITS}x}"


class StringHeapBuilder:
    """Builds an initialized long-string memory image for hardware.

    Long strings are interned: identical byte sequences reuse the same address.
    Dict key equality for LONG_STR relies on this interning invariant — hardware
    compares {size, addr} descriptors only, so two descriptors are equal iff
    they name the same interned payload.
    """

    def __init__(self) -> None:
        self.next_addr = 0
        self.image: dict[int, int] = {}
        self._intern: dict[bytes, int] = {}

    def allocate(self, data: bytes) -> int:
        if not data:
            return 0

        existing = self._intern.get(data)
        if existing is not None:
            return existing

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
        self._intern[data] = addr
        return addr


def tag_constant(
    value: object,
    string_heap: StringHeapBuilder,
    *,
    allow_containers: bool = False,
) -> tuple[int, int]:
    """Encode a Python scalar/string/range constant as (tag, value128).

    When allow_containers is False (preprocess legacy path), tuple/list/dict
    constants raise. The image builder serializes containers itself and does
    not call this for those types. This helper has no object-heap allocator,
    so ranges are inline-only; callers with a HeapImageBuilder must allocate
    an out-of-i32 (start, stop, step) tuple and use make_range_tuple().
    """
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    if isinstance(value, int):
        return TAG_INT, value & VAL_MASK
    if isinstance(value, float):
        return TAG_FLOAT, float_bits(value)
    if isinstance(value, complex):
        return make_complex(value.real, value.imag)
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        if len(encoded) <= SHORT_STR_MAX_BYTES:
            return TAG_SHORT_STR, encode_short_string(encoded)
        if len(encoded) > ((1 << 64) - 1):
            raise ValueError("String constant exceeds 64-bit length field")
        addr = string_heap.allocate(encoded)
        return TAG_LONG_STR, ((len(encoded) & ((1 << 64) - 1)) << 64) | (
            addr & ((1 << 64) - 1)
        )
    if value is None:
        return make_none()
    if isinstance(value, range):
        if not range_fits_inline(value):
            raise ValueError(
                "range constant does not fit inline signed i32 fields; "
                "serialize it with a heap tuple"
            )
        return make_range_inline(value.start, value.stop, value.step)
    if isinstance(value, tuple):
        if not allow_containers:
            raise ValueError(
                "tuple constants require the static heap image builder — not yet supported"
            )
        raise ValueError("tuple constants must be serialized via HeapImageBuilder")
    if isinstance(value, (list, dict, set, frozenset)):
        raise ValueError(
            f"{type(value).__name__} constants require the static heap image "
            "builder — not yet supported"
        )
    return TAG_OBJECT, 0


def pack_code_metadata(
    stacksize: int,
    nlocals: int,
    argcount: int,
    kwonlyargcount: int = 0,
    varargs: bool = False,
    varkeywords: bool = False,
    posonlyargcount: int = 0,
) -> int:
    """Pack code metadata fields into value[81:0].

    Bits [15:0]=argcount, [31:16]=nlocals, [47:32]=stacksize,
    [63:48]=kwonlyargcount, [64]=CO_VARARGS, [65]=CO_VARKEYWORDS,
    [81:66]=posonlyargcount.
    """
    return (
        ((posonlyargcount & 0xFFFF) << 66)
        | ((1 if varkeywords else 0) << 65)
        | ((1 if varargs else 0) << 64)
        | ((kwonlyargcount & 0xFFFF) << 48)
        | ((stacksize & 0xFFFF) << 32)
        | ((nlocals & 0xFFFF) << 16)
        | (argcount & 0xFFFF)
    )


def unpack_code_metadata(
    meta: int,
) -> tuple[int, int, int, int, bool, bool, int]:
    """Return ``(stacksize, nlocals, argcount, kwonlyargcount, varargs,
    varkeywords, posonlyargcount)``.
    """
    return (
        (meta >> 32) & 0xFFFF,
        (meta >> 16) & 0xFFFF,
        meta & 0xFFFF,
        (meta >> 48) & 0xFFFF,
        bool((meta >> 64) & 1),
        bool((meta >> 65) & 1),
        (meta >> 66) & 0xFFFF,
    )


def next_pow2(n: int) -> int:
    if n <= 1:
        return 1
    p = 1
    while p < n:
        p <<= 1
    return p


def dict_slot_count_for_stores(n_names: int) -> int:
    """Pre-size globals dict: next_pow2(max(4, 2 * count))."""
    return next_pow2(max(4, 2 * max(n_names, 0)))


def _float_key_hash(bits: int) -> int:
    """IEEE754 binary64 hash matching pycore_dict_key_hash FLOAT path.

    integer-valued / ±0 → same as INT (incl. -1.0 → -2);
    NaN/Inf/non-integer/overflow → low32 ^ high32 bit-mix.
    """
    bits &= (1 << 64) - 1
    sign = (bits >> 63) & 1
    exp = (bits >> 52) & 0x7FF
    frac = bits & ((1 << 52) - 1)
    mix = ((bits & 0xFFFFFFFF) ^ ((bits >> 32) & 0xFFFFFFFF)) & 0xFFFFFFFF
    if exp == 0x7FF:
        return mix
    if exp == 0 and frac == 0:
        return 0
    if exp < 1023:
        return mix
    uexp = exp - 1023
    if uexp >= 63:
        return mix
    sig = (1 << 52) | frac
    if uexp < 52:
        frac_mask = (1 << (52 - uexp)) - 1
        if frac & frac_mask:
            return mix
        mag = sig >> (52 - uexp)
    else:
        mag = sig << (uexp - 52)
    if not sign:
        return mag & 0xFFFFFFFF
    if mag == 1:
        return 0xFFFFFFFE
    return (-mag) & 0xFFFFFFFF


def dict_key_hash(tag: int, value: int) -> int:
    """Mirror of pycore_dict_key_hash — returns unmasked 32-bit hash.

    INT: -1 → 0xFFFFFFFE (-2); else value[31:0].
    BOOL: value[0] as 0/1.
    FLOAT: integer-valued / ±0 match int; else bit-mix.
    SHORT_STR: XOR of four 32-bit words.
    LONG_STR: low32(addr) ^ low32(size).
    """
    value &= VAL_MASK
    if tag == TAG_INT:
        low64 = value & ((1 << 64) - 1)
        if low64 == (1 << 64) - 1:
            return 0xFFFFFFFE
        return value & 0xFFFFFFFF
    if tag == TAG_BOOL:
        return value & 1
    if tag == TAG_FLOAT:
        return _float_key_hash(value & ((1 << 64) - 1))
    if tag == TAG_SHORT_STR:
        w0 = value & 0xFFFFFFFF
        w1 = (value >> 32) & 0xFFFFFFFF
        w2 = (value >> 64) & 0xFFFFFFFF
        w3 = (value >> 96) & 0xFFFFFFFF
        return (w0 ^ w1 ^ w2 ^ w3) & 0xFFFFFFFF
    if tag == TAG_LONG_STR:
        # value = {size[63:0], addr[63:0]}; hash = value[31:0] ^ value[95:64]
        low_addr = value & 0xFFFFFFFF
        low_size = (value >> 64) & 0xFFFFFFFF
        return (low_addr ^ low_size) & 0xFFFFFFFF
    return value & 0xFFFFFFFF


def _float_as_int64(bits: int) -> int | None:
    """Mirror of pycore_float_as_int64; None if not integer-valued."""
    bits &= (1 << 64) - 1
    sign = (bits >> 63) & 1
    exp = (bits >> 52) & 0x7FF
    frac = bits & ((1 << 52) - 1)
    if exp == 0x7FF:
        return None
    if exp == 0 and frac == 0:
        return 0
    if exp < 1023:
        return None
    uexp = exp - 1023
    if uexp >= 63:
        return None
    sig = (1 << 52) | frac
    if uexp < 52:
        frac_mask = (1 << (52 - uexp)) - 1
        if frac & frac_mask:
            return None
        mag = sig >> (52 - uexp)
    else:
        mag = sig << (uexp - 52)
    if mag >= (1 << 63):
        return None
    return -mag if sign else mag


def dict_key_rich_eq(tag_a: int, val_a: int, tag_b: int, val_b: int) -> bool:
    """Mirror of pycore_dict_key_rich_eq."""
    val_a &= VAL_MASK
    val_b &= VAL_MASK
    numeric = {TAG_INT, TAG_BOOL, TAG_FLOAT}
    if tag_a in numeric and tag_b in numeric:
        def as_int(tag: int, val: int) -> int | None:
            if tag == TAG_INT:
                return val & ((1 << 64) - 1)
            if tag == TAG_BOOL:
                return val & 1
            return _float_as_int64(val)

        ia, ib = as_int(tag_a, val_a), as_int(tag_b, val_b)
        if ia is not None and ib is not None:
            return ia == ib
        if tag_a == TAG_FLOAT and tag_b == TAG_FLOAT:
            return val_a == val_b
        return False
    if tag_a == tag_b and tag_a in (TAG_SHORT_STR, TAG_LONG_STR):
        return val_a == val_b
    if tag_a == tag_b == TAG_CONTROL:
        return (val_a & 0xF) == (val_b & 0xF)
    return False
