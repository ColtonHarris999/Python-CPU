"""Host model of the container key specification.

Mirrors ``pycore_dict_key_hash``, ``pycore_dict_key_rich_eq`` and
``pycore_elem_eq``. ``encoding.dict_key_hash`` remains the hash entry
point; this module is what the image builder, the GC model and the
vector generator import.
"""

from __future__ import annotations

from pycore.tools.encoding import (
    TAG_BOOL,
    TAG_FLOAT,
    TAG_INT,
    TAG_LONG_STR,
    TAG_SHORT_STR,
    VAL_MASK,
    dict_key_hash,
)


def key_hash(tag: int, value: int) -> int:
    return dict_key_hash(tag, value)


def _as_int(tag: int, value: int) -> int | None:
    value &= VAL_MASK
    if tag == TAG_INT:
        return value & ((1 << 64) - 1)
    if tag == TAG_BOOL:
        return value & 1
    return None


def rich_eq(tag_a: int, val_a: int, tag_b: int, val_b: int) -> bool | None:
    """Rich equality for dict/set keys.

    Returns None when the answer needs a LONG_STR payload compare
    (``pycore_str_need_payload_cmp``). Numeric cross-equality matches
    the RTL: INT and BOOL compare as integers; FLOAT is integer-valued
    only through ``dict_key_hash``'s sibling, not here — the RTL uses
    ``pycore_float_as_int64``. This model covers the INT/BOOL/None/
    same-handle cases the vector file locks, and reports None for a
    float so the generator can skip it or supply an expected bit.
    """
    val_a &= VAL_MASK
    val_b &= VAL_MASK
    if tag_a == 0 and tag_b == 0:
        return (val_a & 0xF) == (val_b & 0xF) == 1 or (
            (val_a & 0xFFFFFFFF) == (val_b & 0xFFFFFFFF)
        )
    ia = _as_int(tag_a, val_a)
    ib = _as_int(tag_b, val_b)
    if ia is not None and ib is not None:
        return ia == ib
    if tag_a != tag_b:
        return False
    if tag_a == TAG_LONG_STR and (val_a & 0xFFFFFFFF) != (val_b & 0xFFFFFFFF):
        # Distinct addresses with equal hash/length need the payload lane.
        if (val_a >> 32) == (val_b >> 32):
            return None
        return False
    return val_a == val_b


def elem_eq(tag_a: int, val_a: int, tag_b: int, val_b: int) -> bool:
    """List/tuple ``in`` as implemented today (not yet rich for floats)."""
    ia = _as_int(tag_a, val_a)
    ib = _as_int(tag_b, val_b)
    if ia is not None and ib is not None and tag_a in (TAG_INT, TAG_BOOL) and tag_b in (
        TAG_INT,
        TAG_BOOL,
    ):
        return ia == ib
    if tag_a != tag_b:
        return False
    return (val_a & VAL_MASK) == (val_b & VAL_MASK)


def need_payload_cmp(tag_a: int, val_a: int, tag_b: int, val_b: int) -> bool:
    if tag_a != TAG_LONG_STR or tag_b != TAG_LONG_STR:
        return False
    if (val_a & 0xFFFFFFFF) == (val_b & 0xFFFFFFFF):
        return False
    return (val_a >> 32) == (val_b >> 32)
