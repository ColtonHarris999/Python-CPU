"""Tagged-value and heap decoding for the simulator UI."""

from __future__ import annotations

import struct
import sys
from pathlib import Path
from typing import Any

# Allow importing pycore/tools helpers.
_TOOLS = Path(__file__).resolve().parents[2] / "pycore" / "tools"
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from encoding import (  # noqa: E402
    CODE_FIELD_CO_VARNAMES,
    CODE_FIELD_METADATA,
    CODE_OBJECT_NFIELDS,
    CTL_NONE,
    CTL_NULL,
    CTL_UNINIT,
    MUT_BYTEARRAY,
    MUT_CONTAMINATED_BIT,
    MUT_DEQUE,
    MUT_DICT,
    MUT_LIST,
    MUT_SET,
    SHORT_STR_DATA_SHIFT,
    SHORT_STR_MAX_BYTES,
    SHORT_STR_SIZE_SHIFT,
    TAG_BOOL,
    TAG_BYTES,
    TAG_CODE_OBJECT,
    TAG_COMPLEX,
    TAG_CONTROL,
    TAG_FLOAT,
    TAG_FROZENSET,
    TAG_INT,
    TAG_ITER,
    TAG_LONG_STR,
    TAG_MUT_COLLEC,
    TAG_OBJECT,
    TAG_RANGE,
    TAG_SHORT_STR,
    TAG_TOMBSTONE,
    TAG_TUPLE,
    make_list,
    mut_addr,
    mut_contaminated,
    mut_kind,
    ob_kind,
)

# Re-export for tests / callers.
__all__ = [
    "DmemImage",
    "TAG_INT",
    "TAG_MUT_COLLEC",
    "decode_entry",
    "decode_entry_hex",
    "decode_heap_object",
    "make_list",
    "mut_contaminated",
    "opcode_name",
    "parse_entry_hex",
    "trap_name",
]

TAG_NAMES = {
    TAG_CONTROL: "CONTROL",
    TAG_INT: "INT",
    TAG_FLOAT: "FLOAT",
    TAG_COMPLEX: "COMPLEX",
    TAG_BOOL: "BOOL",
    TAG_ITER: "ITER",
    TAG_TUPLE: "TUPLE",
    TAG_SHORT_STR: "SHORT_STR",
    TAG_LONG_STR: "LONG_STR",
    TAG_MUT_COLLEC: "MUT_COLLEC",
    TAG_OBJECT: "OBJECT",
    TAG_RANGE: "RANGE",
    TAG_BYTES: "BYTES",
    TAG_CODE_OBJECT: "CODE_OBJECT",
    TAG_TOMBSTONE: "TOMBSTONE",
    TAG_FROZENSET: "FROZENSET",
}

MUT_KIND_NAMES = {
    MUT_LIST: "LIST",
    MUT_DICT: "DICT",
    MUT_SET: "SET",
    MUT_BYTEARRAY: "BYTEARRAY",
    MUT_DEQUE: "DEQUE",
}

TRAP_NAMES = {
    0: "NONE",
    1: "TYPE",
    2: "STACK",
    3: "DIV_ZERO",
    4: "FPU_EXCEPTION",
    5: "ILLEGAL_OPCODE",
    6: "CALL_FILTER",
    7: "MEM_FAULT",
    8: "ADDR_ALIGN",
    9: "LIST_GROW",
    10: "LIST_EXTEND",
    11: "DICT_GROW",
    12: "LIST_DELETE",
    13: "SET_GROW",
    14: "SET_UPDATE",
    15: "ATTR_ERROR",
    16: "BUILTIN_CALL",
    17: "RAISE",
    18: "SLICE",
    19: "DICT_UPDATE",
    20: "DICT_MERGE",
}

RECOVERABLE_TRAPS = {9, 10, 11, 12, 13, 14, 16, 18, 19, 20}


def trap_name(code: int | None) -> str | None:
    if code is None:
        return None
    return TRAP_NAMES.get(int(code), f"UNKNOWN({code})")


def parse_entry_hex(hex_str: str) -> tuple[int, int]:
    """Parse a 33-hex-digit (or shorter) tagged entry into (tag, value)."""
    raw = int(hex_str, 16)
    tag = (raw >> 128) & 0xF
    value = raw & ((1 << 128) - 1)
    return tag, value


def _signed_i64(value: int) -> int:
    v = value & ((1 << 64) - 1)
    if v & (1 << 63):
        v -= 1 << 64
    return v


def _decode_short_str(value: int) -> str:
    n = (value >> SHORT_STR_SIZE_SHIFT) & 0xF
    n = min(n, SHORT_STR_MAX_BYTES)
    data = bytearray()
    for idx in range(n):
        shift = SHORT_STR_DATA_SHIFT + (SHORT_STR_MAX_BYTES - 1 - idx) * 8
        data.append((value >> shift) & 0xFF)
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.hex()


def decode_entry(tag: int, value: int) -> dict[str, Any]:
    """Return a UI-friendly decode of a tagged entry."""
    name = TAG_NAMES.get(tag, f"TAG_{tag}")
    out: dict[str, Any] = {
        "tag": name,
        "tag_id": tag,
        "raw": f"0x{(tag << 128 | (value & ((1 << 128) - 1))):033x}",
        "display": name,
        "contaminated": None,
        "kind": None,
        "addr": None,
    }
    if tag == TAG_CONTROL:
        ctl = value & 0xF
        label = {CTL_UNINIT: "UNINIT", CTL_NONE: "None", CTL_NULL: "NULL"}.get(
            ctl, f"CTL({ctl})"
        )
        out["display"] = label
    elif tag == TAG_INT:
        out["display"] = str(_signed_i64(value))
    elif tag == TAG_BOOL:
        out["display"] = "True" if (value & 1) else "False"
    elif tag == TAG_FLOAT:
        bits = value & ((1 << 64) - 1)
        out["display"] = repr(struct.unpack("<d", struct.pack("<Q", bits))[0])
    elif tag == TAG_COMPLEX:
        real = struct.unpack("<d", struct.pack("<Q", value & ((1 << 64) - 1)))[0]
        imag = struct.unpack("<d", struct.pack("<Q", (value >> 64) & ((1 << 64) - 1)))[0]
        out["display"] = f"({real}+{imag}j)"
    elif tag == TAG_SHORT_STR:
        s = _decode_short_str(value)
        out["display"] = repr(s)
    elif tag == TAG_LONG_STR:
        length = (value >> 64) & 0xFFFFFFFF
        addr = value & ((1 << 64) - 1)
        out["addr"] = addr
        out["display"] = f"str@{addr:#x} len={length}"
    elif tag == TAG_TUPLE:
        size = (value >> 64) & 0xFFFFFFFF
        addr = value & ((1 << 64) - 1)
        out["addr"] = addr
        out["display"] = f"tuple@{addr:#x} len={size}"
    elif tag == TAG_MUT_COLLEC:
        kind = mut_kind(value)
        contam = mut_contaminated(value)
        addr = mut_addr(value)
        kname = MUT_KIND_NAMES.get(kind, f"KIND({kind})")
        out["kind"] = kname
        out["contaminated"] = contam
        out["addr"] = addr
        cflag = " contaminated" if contam else ""
        out["display"] = f"{kname.lower()}@{addr:#x}{cflag}"
    elif tag == TAG_CODE_OBJECT:
        addr = value & ((1 << 64) - 1)
        out["addr"] = addr
        out["display"] = f"code@{addr:#x}"
    elif tag == TAG_OBJECT:
        addr = value & ((1 << 64) - 1)
        out["addr"] = addr
        out["display"] = f"object@{addr:#x}"
    elif tag == TAG_RANGE:
        if value & (1 << 127):
            addr = value & ((1 << 64) - 1)
            out["addr"] = addr
            out["display"] = f"range@{addr:#x}"
        else:
            start = _signed_i32((value >> 64) & 0xFFFFFFFF)
            stop = _signed_i32((value >> 32) & 0xFFFFFFFF)
            step = _signed_i32(value & 0xFFFFFFFF)
            out["display"] = f"range({start}, {stop}, {step})"
    elif tag == TAG_TOMBSTONE:
        out["display"] = "TOMBSTONE"
    else:
        out["display"] = f"{name}(0x{value:x})"
    return out


def _signed_i32(v: int) -> int:
    v &= 0xFFFFFFFF
    if v & 0x80000000:
        v -= 0x100000000
    return v


def decode_entry_hex(hex_str: str) -> dict[str, Any]:
    return decode_entry(*parse_entry_hex(hex_str))


class DmemImage:
    """128-bit word dmem image (flat list of ints)."""

    WORD_BYTES = 16

    def __init__(self, words: list[int]):
        self.words = words

    @classmethod
    def from_hex_file(cls, path: Path) -> "DmemImage":
        words: list[int] = []
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("@"):
                continue
            words.append(int(line, 16))
        return cls(words)

    def read_word(self, addr: int) -> int:
        if addr % self.WORD_BYTES:
            raise ValueError(f"unaligned dmem read {addr:#x}")
        idx = addr // self.WORD_BYTES
        if idx < 0 or idx >= len(self.words):
            raise IndexError(f"dmem addr {addr:#x} out of range")
        return self.words[idx]

    def read_entry_pair(self, addr: int) -> tuple[int, int]:
        """Read value@addr and tag@addr+16 as used by heap objects."""
        val = self.read_word(addr)
        tag_word = self.read_word(addr + 16)
        tag = tag_word & 0xF
        return tag, val


def decode_heap_object(dmem: DmemImage, tag: int, value: int) -> dict[str, Any]:
    """Best-effort heap object expand for LIST/DICT/SET/TUPLE/CODE/etc."""
    base = decode_entry(tag, value)
    try:
        if tag == TAG_TUPLE:
            size = (value >> 64) & 0xFFFFFFFF
            addr = value & ((1 << 64) - 1)
            elems = []
            for i in range(min(size, 64)):
                # Tuple elements are packed as consecutive 16B value words with
                # tags in a side array in some layouts; image builder stores
                # entries as 32B (value+tag) pairs — match heap_image.
                e_tag, e_val = dmem.read_entry_pair(addr + i * 32)
                elems.append(decode_entry(e_tag, e_val))
            base["elements"] = elems
            base["summary"] = f"tuple len={size}"
        elif tag == TAG_MUT_COLLEC:
            kind = mut_kind(value)
            addr = mut_addr(value)
            contam = mut_contaminated(value)
            header = dmem.read_word(addr)
            if kind == MUT_LIST:
                # header: { capacity[127:64], length[63:0] }; ob_item @ +16
                length = header & ((1 << 64) - 1)
                capacity = (header >> 64) & ((1 << 64) - 1)
                ob_item_word = dmem.read_word(addr + 16)
                ob_item = ob_item_word & ((1 << 64) - 1)
                elems = []
                for i in range(min(int(length), 64)):
                    e_tag, e_val = dmem.read_entry_pair(ob_item + i * 32)
                    elems.append(decode_entry(e_tag, e_val))
                base["length"] = int(length)
                base["capacity"] = int(capacity)
                base["elements"] = elems
                base["summary"] = (
                    f"list len={length} cap={capacity}"
                    + (" contaminated" if contam else "")
                )
            elif kind in (MUT_DICT, MUT_SET):
                # header: { slot_count[127:64], used[63:0] }
                used = header & ((1 << 64) - 1)
                slots = (header >> 64) & ((1 << 64) - 1)
                base["used"] = int(used)
                base["slots"] = int(slots)
                kname = MUT_KIND_NAMES.get(kind, "COLLEC")
                base["summary"] = (
                    f"{kname.lower()} used={used} slots={slots}"
                    + (" contaminated" if contam else "")
                )
                if contam:
                    base["routing_note"] = (
                        "contaminated — bulk update/merge may stay on pycore"
                    )
            else:
                base["summary"] = base["display"]
        elif tag == TAG_CODE_OBJECT:
            addr = value & ((1 << 64) - 1)
            fields = []
            for i in range(CODE_OBJECT_NFIELDS):
                # Each field is a 32B tagged entry (value @ +0, tag @ +16).
                try:
                    f_tag, f_val = dmem.read_entry_pair(addr + i * 32)
                    fields.append(decode_entry(f_tag, f_val))
                except Exception as exc:  # noqa: BLE001
                    fields.append({"error": str(exc)})
            meta = fields[CODE_FIELD_METADATA] if len(fields) > CODE_FIELD_METADATA else {}
            base["fields"] = fields
            base["summary"] = f"code object @ {addr:#x}"
            # Metadata packed in INT value when present.
            if meta.get("tag") == "INT":
                mv = int(meta.get("display", "0"))
                base["argcount"] = mv & 0xFFFF
                base["nlocals"] = (mv >> 16) & 0xFFFF
                base["stacksize"] = (mv >> 32) & 0xFFFF
                base["kwonlyargcount"] = (mv >> 48) & 0xFFFF
            # co_varnames for frame labeling
            if len(fields) > CODE_FIELD_CO_VARNAMES:
                base["co_varnames_entry"] = fields[CODE_FIELD_CO_VARNAMES]
        else:
            base["summary"] = base["display"]
    except Exception as exc:  # noqa: BLE001
        base["summary"] = base.get("display", "?")
        base["error"] = str(exc)
    return base


# CPython 3.14.6 opmap subset (mirrors pycore/rtl/pycore_defs.svh). Do not use
# the host `opcode` module — numbers differ across CPython versions.
_OPNAMES_314: dict[int, str] = {
    0: "CACHE",
    4: "CALL_FUNCTION_EX",
    8: "DELETE_SUBSCR",
    9: "END_FOR",
    16: "GET_ITER",
    23: "MAKE_FUNCTION",
    27: "NOP",
    28: "NOT_TAKEN",
    30: "POP_ITER",
    31: "POP_TOP",
    33: "PUSH_NULL",
    35: "RETURN_VALUE",
    38: "STORE_SUBSCR",
    39: "TO_BOOL",
    40: "UNARY_INVERT",
    41: "UNARY_NEGATIVE",
    42: "UNARY_NOT",
    44: "BINARY_OP",
    46: "BUILD_LIST",
    47: "BUILD_MAP",
    48: "BUILD_SET",
    51: "BUILD_TUPLE",
    52: "CALL",
    53: "CALL_INTRINSIC_1",
    55: "CALL_KW",
    56: "COMPARE_OP",
    57: "CONTAINS_OP",
    59: "COPY",
    63: "DELETE_FAST",
    66: "DICT_MERGE",
    67: "DICT_UPDATE",
    69: "EXTENDED_ARG",
    70: "FOR_ITER",
    74: "IS_OP",
    75: "JUMP_BACKWARD",
    77: "JUMP_FORWARD",
    78: "LIST_APPEND",
    79: "LIST_EXTEND",
    82: "LOAD_CONST",
    84: "LOAD_FAST",
    85: "LOAD_FAST_AND_CLEAR",
    86: "LOAD_FAST_BORROW",
    87: "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
    88: "LOAD_FAST_CHECK",
    89: "LOAD_FAST_LOAD_FAST",
    92: "LOAD_GLOBAL",
    93: "LOAD_NAME",
    94: "LOAD_SMALL_INT",
    98: "MAP_ADD",
    100: "POP_JUMP_IF_FALSE",
    101: "POP_JUMP_IF_NONE",
    102: "POP_JUMP_IF_NOT_NONE",
    103: "POP_JUMP_IF_TRUE",
    104: "RAISE_VARARGS",
    107: "SET_ADD",
    109: "SET_UPDATE",
    112: "STORE_FAST",
    113: "STORE_FAST_LOAD_FAST",
    114: "STORE_FAST_STORE_FAST",
    115: "STORE_GLOBAL",
    116: "STORE_NAME",
    117: "SWAP",
    118: "UNPACK_EX",
    119: "UNPACK_SEQUENCE",
    128: "RESUME",
}


def opcode_name(op: int) -> str:
    return _OPNAMES_314.get(int(op), f"OP_{op}")
