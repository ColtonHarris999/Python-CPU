"""Static heap-image builder for PyCore dmem preload.

Lays out dicts, tuples, lists, and code objects into a 128-bit-slot dmem hex
image using the same hash/probe rules as the RTL (`pycore_dict_key_hash` in
pycore_defs.svh).

Tagged entries are (tag: int, value: int) with value a 128-bit unsigned int.
"""

from __future__ import annotations

import pathlib
from dataclasses import dataclass, field

from encoding import (
    BOOT_RECORD_ADDR,
    CODE_FIELD_CO_CONSTS,
    CODE_FIELD_CO_NAMES,
    CODE_FIELD_ENTRY_SLOT,
    CODE_FIELD_METADATA,
    CODE_OBJECT_BYTES,
    CODE_OBJECT_NFIELDS,
    HEAP_BASE,
    HEAP_LIMIT,
    TAG_CODE_OBJECT,
    TAG_DICT,
    TAG_INT,
    TAG_LIST,
    TAG_NULL,
    TAG_TUPLE,
    TAG_UNINIT,
    bool_value,
    dict_key_hash,
    dict_slot_count_for_stores,
    encode_short_str,
    int_value,
    pack_code_metadata,
)

# Re-export tag constants / hash for callers / tests.
TAG_BOOL = 0b0011
TAG_FLOAT = 0b0010
TAG_SHORT_STR = 0b0110
TAG_LONG_STR = 0b0111
TAG_NONE = 0b1111
TAG_UNUSED = TAG_NULL  # renamed; kept as alias

Tagged = tuple[int, int]  # (tag, value128)


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
    # v2 layout (Phase A, growable split object/buffer — mirrors
    # pycore_defs.svh's LIST section):
    #   obj_addr + 0  : header  { capacity[63:0], length[63:0] }
    #   obj_addr + 16 : { 64'd0, ob_item[63:0] }  (buffer byte address)
    #   ob_item + i*32      : element[i] value
    #   ob_item + i*32 + 16 : element[i] tag
    # Empty list: capacity=0, length=0, ob_item=0 (object only, no buffer).
    LIST_OBJ_BYTES = 32

    def alloc_list(self, elements: list[Tagged]) -> Tagged:
        return self.alloc_list_with_capacity(elements, len(elements))

    def alloc_list_with_capacity(
        self, elements: list[Tagged], capacity: int
    ) -> Tagged:
        """Like alloc_list, but reserves buffer room for `capacity` elements
        while only initializing len(elements) of them.

        BUILD_LIST always allocates capacity == length exactly (matching
        CPython list-literal semantics — see CONT_BUILD_LIST), so a real
        program can never produce a list with spare capacity.  Hand-built
        test fixtures that need to exercise the LIST_APPEND fast path
        (spare capacity, no trap) use this to pre-populate a list image
        with capacity > length directly.
        """
        n = len(elements)
        if capacity < n:
            raise ValueError("capacity must be >= number of elements")
        obj_addr = self._alloc(self.LIST_OBJ_BYTES)
        ob_item = 0
        if capacity:
            ob_item = self._alloc(capacity * 32)
            for i, (tag, val) in enumerate(elements):
                self._write_tagged(ob_item + i * 32, tag, val)
        self._write(obj_addr, ((capacity & ((1 << 64) - 1)) << 64) | (n & ((1 << 64) - 1)))
        self._write(obj_addr + 16, ob_item & ((1 << 64) - 1))
        return TAG_LIST, obj_addr

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
    # v2 layout (relocatable table — mirrors pycore_defs.svh DICT section):
    #   obj + 0  : header { slot_count[63:0], used[63:0] }
    #   obj + 16 : { 64'd0, table_ptr[63:0] }  (0 if slot_count==0)
    #   table + i*64 + 0/16/32/48 : key val/tag, value val/tag
    # BUILD_MAP-style images allocate object then table contiguously.
    DICT_OBJ_BYTES = 32

    def alloc_dict(
        self,
        pairs: list[tuple[Tagged, Tagged]],
        slot_count: int | None = None,
    ) -> Tagged:
        n = len(pairs)
        if slot_count is None:
            slot_count = dict_min_slots(n)
        if slot_count < 0 or (
            slot_count > 0 and (slot_count & (slot_count - 1)) != 0
        ):
            raise ValueError("slot_count must be 0 or a positive power of two")
        # Interim policy: keep at least one empty slot when a table exists.
        if slot_count > 0 and n >= slot_count:
            raise ValueError(
                f"dict would fill table completely ({n} keys, {slot_count} slots)"
            )
        if slot_count == 0 and n > 0:
            raise ValueError("non-empty dict requires slot_count > 0")

        obj = self._alloc(self.DICT_OBJ_BYTES)
        table = 0
        if slot_count:
            table = self._alloc(slot_count * 64)
            # Zero all slots (empty sentinel = UNINIT key tag).
            for i in range(slot_count):
                self._write(table + i * 64, 0)              # kval
                self._write(table + 16 + i * 64, TAG_UNINIT)  # ktag
                self._write(table + 32 + i * 64, 0)          # vval
                self._write(table + 48 + i * 64, 0)          # vtag

        self._write(
            obj, ((slot_count & ((1 << 64) - 1)) << 64) | 0
        )  # used=0 for now
        self._write(obj + 16, table & ((1 << 64) - 1))

        used = 0
        if slot_count:
            mask = slot_count - 1
            for (ktag, kval), (vtag, vval) in pairs:
                h = dict_key_hash(ktag, kval) & mask
                probes = 0
                idx = h
                while probes < slot_count:
                    ktag_addr = table + 16 + idx * 64
                    existing_tag = self.words.get(ktag_addr, TAG_UNINIT) & 0xF
                    if existing_tag == TAG_UNINIT:
                        self._write_tagged(table + idx * 64, ktag, kval)
                        self._write_tagged(table + 32 + idx * 64, vtag, vval)
                        used += 1
                        break
                    # Overwrite on key match (same tag + equality rules).
                    existing_val = self.words.get(table + idx * 64, 0)
                    if existing_tag == ktag and _key_equal(ktag, existing_val, kval):
                        self._write_tagged(table + 32 + idx * 64, vtag, vval)
                        break
                    idx = (idx + 1) & mask
                    probes += 1
                else:
                    raise RuntimeError("dict probe exhausted during image build")

        self._write(
            obj,
            ((slot_count & ((1 << 64) - 1)) << 64) | (used & ((1 << 64) - 1)),
        )
        return TAG_DICT, obj

    # ---- CODE OBJECT ----
    def add_code_object(
        self,
        entry_slot: int,
        co_consts: Tagged,
        co_names: Tagged,
        *,
        stacksize: int,
        nlocals: int,
        argcount: int,
    ) -> Tagged:
        """Allocate a 128-byte code object (4 tagged-entry fields).

        field 0 : entry_slot (INT) — imem slot index of the first code unit
        field 1 : co_consts  (TUPLE handle)
        field 2 : co_names   (TUPLE handle)
        field 3 : metadata   (INT) — packed {stacksize, nlocals, argcount}
        """
        assert CODE_OBJECT_NFIELDS == 4
        assert co_consts[0] == TAG_TUPLE
        assert co_names[0] == TAG_TUPLE
        addr = self._alloc(CODE_OBJECT_BYTES)
        fields: list[Tagged] = [
            (TAG_INT, int_value(entry_slot)),  # field 0
            co_consts,                         # field 1
            co_names,                          # field 2
            (TAG_INT, pack_code_metadata(stacksize, nlocals, argcount)),  # field 3
        ]
        # Silence unused-import lint for field index constants (documented API).
        assert CODE_FIELD_ENTRY_SLOT == 0
        assert CODE_FIELD_CO_CONSTS == 1
        assert CODE_FIELD_CO_NAMES == 2
        assert CODE_FIELD_METADATA == 3
        for i, (tag, val) in enumerate(fields):
            self._write_tagged(addr + i * 32, tag, val)
        return TAG_CODE_OBJECT, addr & ((1 << 64) - 1)

    def write_boot_record(
        self,
        module_code: Tagged,
        globals_dict: Tagged,
        addr: int = BOOT_RECORD_ADDR,
    ) -> None:
        """Write the two-pair boot record below the heap base.

        pair 0 : module code object handle (CODE_OBJECT)
        pair 1 : globals dict handle (DICT)
        """
        if module_code[0] != TAG_CODE_OBJECT:
            raise ValueError("boot record pair 0 must be CODE_OBJECT")
        if globals_dict[0] != TAG_DICT:
            raise ValueError("boot record pair 1 must be DICT")
        if addr % 16 != 0:
            raise ValueError(f"boot record addr must be 16-byte aligned, got {addr:#x}")
        self._write_tagged(addr, module_code[0], module_code[1])
        self._write_tagged(addr + 32, globals_dict[0], globals_dict[1])

    def alloc_empty_globals(self, n_store_names: int) -> Tagged:
        """Empty dict pre-sized for runtime STORE_NAME / STORE_GLOBAL inserts."""
        slots = dict_slot_count_for_stores(n_store_names)
        return self.alloc_dict([], slot_count=slots)

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
