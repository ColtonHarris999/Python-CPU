"""Shared tagged-value encoding for PyCore tooling.

Used by preprocess.py (legacy single-function path) and image_from_source.py
(primary module-image path). Tag constants mirror pycore/rtl/pycore_defs.svh.
"""

from __future__ import annotations

import struct
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    pass

# Mirror pycore/rtl/pycore_defs.svh tags.
TAG_UNINIT = 0b0000
TAG_INT = 0b0001
TAG_FLOAT = 0b0010
TAG_BOOL = 0b0011
TAG_PTR = 0b0100
TAG_TUPLE = 0b0101
TAG_SHORT_STR = 0b0110
TAG_LONG_STR = 0b0111
TAG_OBJECT = 0b1000
TAG_DICT = 0b1001
TAG_LIST = 0b1010
TAG_SET = 0b1011
TAG_CODE_OBJECT = 0b1100
TAG_FRAME_OBJECT = 0b1101
TAG_NULL = 0b1110  # formerly TAG_UNUSED; CPython self_or_null sentinel
TAG_NONE = 0b1111

# Back-compat alias used by older preprocess code paths.
TAG_UNUSED = TAG_NULL
TAG_UNINITIALIZED = TAG_UNINIT

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

HEAP_BASE = 0x0400
HEAP_LIMIT = 0x2000
BOOT_RECORD_ADDR = 0x03E0

# Code-object field indices (tuple-element convention at code addr).
CODE_FIELD_ENTRY_SLOT = 0
CODE_FIELD_CO_CONSTS = 1
CODE_FIELD_CO_NAMES = 2
CODE_FIELD_METADATA = 3
CODE_OBJECT_NFIELDS = 4
CODE_OBJECT_BYTES = CODE_OBJECT_NFIELDS * 32  # 128


def float_bits(value: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", value))[0]


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


def bool_value(b: bool) -> int:
    return 1 if b else 0


def format_entry(tag: int, value: int) -> str:
    entry = ((tag & 0xF) << VAL_WIDTH) | (value & VAL_MASK)
    return f"{entry:0{ENTRY_HEX_DIGITS}x}"


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
    """Encode a Python scalar/string constant as (tag, value128).

    When allow_containers is False (preprocess legacy path), tuple/list/dict
    constants raise. The image builder serializes containers itself and does
    not call this for those types.
    """
    if isinstance(value, bool):
        return TAG_BOOL, int(value)
    if isinstance(value, int):
        return TAG_INT, value & VAL_MASK
    if isinstance(value, float):
        return TAG_FLOAT, float_bits(value)
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
        return TAG_NONE, 0
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


def pack_code_metadata(stacksize: int, nlocals: int, argcount: int) -> int:
    """Pack {stacksize[15:0], nlocals[15:0], argcount[15:0]} into value[47:0]."""
    return (
        ((stacksize & 0xFFFF) << 32)
        | ((nlocals & 0xFFFF) << 16)
        | (argcount & 0xFFFF)
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
