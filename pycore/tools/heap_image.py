"""Static heap-image builder for PyCore dmem preload.

Lays out dicts, tuples, and lists into a 128-bit-slot dmem hex image using the
same hash/probe rules as the RTL (`pycore_dict_key_hash` in pycore_defs.svh).
Does not yet understand code objects — scalar and string-descriptor values are
enough to unblock memory-image boot work.

Tagged entries are (tag: int, value: int) with value a 128-bit unsigned int.
"""

from __future__ import annotations

import pathlib
from dataclasses import dataclass, field

# Mirror pycore/rtl/pycore_defs.svh tags.
TAG_UNINIT = 0b0000
TAG_INT = 0b0001
TAG_FLOAT = 0b0010
TAG_BOOL = 0b0011
TAG_TUPLE = 0b0101
TAG_SHORT_STR = 0b0110
TAG_LONG_STR = 0b0111
TAG_DICT = 0b1001
TAG_LIST = 0b1010
TAG_NONE = 0b1111

HEAP_BASE = 0x0400
HEAP_LIMIT = 0x2000

Tagged = tuple[int, int]  # (tag, value128)


def dict_key_hash(tag: int, value: int) -> int:
    """Mirror of pycore_dict_key_hash — returns unmasked 32-bit hash.

    Documented RTL agreement vectors (see tests):
      INT 7      -> 0x00000007
      BOOL True  -> 0x00000001
      SHORT_STR "x" payload fold — see unit test
      LONG_STR {size, addr} -> (addr & 0xffffffff) ^ ((size >> 0) & ... low 32 of size at [95:64])
    """
    value &= (1 << 128) - 1
    if tag in (TAG_INT, TAG_BOOL):
        return value & 0xFFFFFFFF
    if tag == TAG_SHORT_STR:
        w0 = value & 0xFFFFFFFF
        w1 = (value >> 32) & 0xFFFFFFFF
        w2 = (value >> 64) & 0xFFFFFFFF
        w3 = (value >> 96) & 0xFFFFFFFF
        return (w0 ^ w1 ^ w2 ^ w3) & 0xFFFFFFFF
    if tag == TAG_LONG_STR:
        # value = {size[63:0], addr[63:0]}; hash = value[31:0] ^ value[95:64]
        low_addr = value & 0xFFFFFFFF
        low_size = (value >> 64) & 0xFFFFFFFF  # bits [95:64] == size[31:0]
        return (low_addr ^ low_size) & 0xFFFFFFFF
    return value & 0xFFFFFFFF


def dict_min_slots(n_pairs: int) -> int:
    """Mirror of pycore_dict_min_slots."""
    if n_pairs <= 2:
        return 4
    if n_pairs <= 4:
        return 8
    if n_pairs <= 8:
        return 16
    if n_pairs <= 16:
        return 32
    if n_pairs <= 32:
        return 64
    return 128


def encode_short_str(data: bytes) -> int:
    """Encode a ≤15-byte string into the SHORT_STR value field."""
    if len(data) > 15:
        raise ValueError("short string max 15 bytes")
    payload = 0
    for idx, byte in enumerate(data):
        shift = 4 + (15 - 1 - idx) * 8
        payload |= int(byte) << shift
    payload |= (len(data) & 0xF) << 124
    return payload


def int_value(n: int) -> int:
    return n & ((1 << 128) - 1)


def bool_value(b: bool) -> int:
    return 1 if b else 0


@dataclass
class HeapImageBuilder:
    """Bump-allocate containers into a byte-addressed 128-bit-slot image."""

    base: int = HEAP_BASE
    limit: int = HEAP_LIMIT
    ptr: int = field(init=False)
    # byte_addr -> 128-bit word
    words: dict[int, int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.ptr = self.base

    @property
    def end_ptr(self) -> int:
        """First free byte — use as HEAP_INIT_PTR."""
        return self.ptr

    def _alloc(self, nbytes: int) -> int:
        if nbytes % 16 != 0:
            raise ValueError(f"allocation must be 16-byte aligned, got {nbytes}")
        addr = self.ptr
        if addr + nbytes > self.limit:
            raise MemoryError(
                f"heap OOM: need {nbytes} at {addr:#x}, limit {self.limit:#x}"
            )
        self.ptr = addr + nbytes
        return addr

    def _write(self, addr: int, word: int) -> None:
        if addr % 16 != 0:
            raise ValueError(f"unaligned write {addr:#x}")
        self.words[addr] = word & ((1 << 128) - 1)

    def _write_tagged(self, val_addr: int, tag: int, value: int) -> None:
        self._write(val_addr, value)
        self._write(val_addr + 16, tag & 0xF)

    # ---- LIST ----
    def alloc_list(self, elements: list[Tagged]) -> Tagged:
        n = len(elements)
        base = self._alloc(16 + n * 32)
        self._write(base, ((n & ((1 << 64) - 1)) << 64) | (n & ((1 << 64) - 1)))
        for i, (tag, val) in enumerate(elements):
            self._write_tagged(base + 16 + i * 32, tag, val)
        return TAG_LIST, base

    # ---- TUPLE ----
    def alloc_tuple(self, elements: list[Tagged]) -> Tagged:
        n = len(elements)
        if n == 0:
            # Empty tuple: no dmem payload; address is the would-be base.
            return TAG_TUPLE, (0 << 64) | (self.ptr & ((1 << 64) - 1))
        base = self._alloc(n * 32)
        for i, (tag, val) in enumerate(elements):
            self._write_tagged(base + i * 32, tag, val)
        return TAG_TUPLE, ((n & ((1 << 64) - 1)) << 64) | (base & ((1 << 64) - 1))

    # ---- DICT ----
    def alloc_dict(
        self,
        pairs: list[tuple[Tagged, Tagged]],
        slot_count: int | None = None,
    ) -> Tagged:
        n = len(pairs)
        if slot_count is None:
            slot_count = dict_min_slots(n)
        if slot_count <= 0 or (slot_count & (slot_count - 1)) != 0:
            raise ValueError("slot_count must be a positive power of two")
        # Interim policy: keep at least one empty slot.
        if n >= slot_count:
            raise ValueError(
                f"dict would fill table completely ({n} keys, {slot_count} slots)"
            )

        base = self._alloc(16 + slot_count * 64)
        # Zero all slots (empty sentinel = UNINIT key tag).
        self._write(base, ((slot_count & ((1 << 64) - 1)) << 64) | 0)  # used=0 for now
        for i in range(slot_count):
            self._write(base + 16 + i * 64, 0)       # kval
            self._write(base + 32 + i * 64, TAG_UNINIT)  # ktag
            self._write(base + 48 + i * 64, 0)       # vval
            self._write(base + 64 + i * 64, 0)       # vtag

        used = 0
        mask = slot_count - 1
        for (ktag, kval), (vtag, vval) in pairs:
            h = dict_key_hash(ktag, kval) & mask
            probes = 0
            idx = h
            while probes < slot_count:
                ktag_addr = base + 32 + idx * 64
                existing_tag = self.words.get(ktag_addr, TAG_UNINIT) & 0xF
                if existing_tag == TAG_UNINIT:
                    self._write_tagged(base + 16 + idx * 64, ktag, kval)
                    self._write_tagged(base + 48 + idx * 64, vtag, vval)
                    used += 1
                    break
                # Overwrite on key match (same tag + equality rules).
                existing_val = self.words.get(base + 16 + idx * 64, 0)
                if existing_tag == ktag and _key_equal(ktag, existing_val, kval):
                    self._write_tagged(base + 48 + idx * 64, vtag, vval)
                    break
                idx = (idx + 1) & mask
                probes += 1
            else:
                raise RuntimeError("dict probe exhausted during image build")

        self._write(base, ((slot_count & ((1 << 64) - 1)) << 64) | (used & ((1 << 64) - 1)))
        return TAG_DICT, base

    def write_hex(self, path: pathlib.Path, total_bytes: int | None = None) -> None:
        """Write a $readmemh image of 128-bit words covering [0, total_bytes).

        Words are little-endian by address order (addr 0, 16, 32, ...).
        Missing addresses are written as zero so the file covers the full bank
        span when total_bytes is set (default: end of image rounded up, at
        least through self.ptr).
        """
        path = pathlib.Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        if total_bytes is None:
            total_bytes = max(self.ptr, max(self.words.keys(), default=0) + 16)
        # Round up to a whole word.
        nwords = (total_bytes + 15) // 16
        lines: list[str] = []
        for i in range(nwords):
            addr = i * 16
            word = self.words.get(addr, 0)
            lines.append(f"{word:032x}")
        path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _key_equal(tag: int, a: int, b: int) -> bool:
    a &= (1 << 128) - 1
    b &= (1 << 128) - 1
    if tag == TAG_INT:
        return (a & ((1 << 64) - 1)) == (b & ((1 << 64) - 1))
    if tag == TAG_BOOL:
        return (a & 1) == (b & 1)
    if tag in (TAG_SHORT_STR, TAG_LONG_STR):
        return a == b
    return False
