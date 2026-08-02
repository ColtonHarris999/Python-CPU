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
    CODE_FIELD_CO_DEFAULTS,
    CODE_FIELD_CO_KWDEFAULTS,
    CODE_FIELD_CO_NAMES,
    CODE_FIELD_CO_VARNAMES,
    CODE_FIELD_ENTRY_SLOT,
    CODE_FIELD_METADATA,
    CODE_OBJECT_BYTES,
    CODE_OBJECT_NFIELDS,
    HEAP_BASE,
    HEAP_LIMIT,
    OBK_BOUND_METHOD,
    OBK_BUILTIN,
    OBK_BYTEARRAY,
    OBK_EXCEPTION,
    OBK_INSTANCE,
    OBK_TYPE,
    OBJ_BOUND_METHOD_BYTES,
    OBJ_BUILTIN_BYTES,
    OBJ_BYTEARRAY_BYTES,
    OBJ_EXCEPTION_BYTES,
    OBJ_INSTANCE_BYTES,
    OBJ_TYPE_BYTES,
    TAG_BOOL,
    TAG_CODE_OBJECT,
    TAG_CONTROL,
    TAG_FLOAT,
    TAG_INT,
    TAG_LONG_STR,
    TAG_MUT_COLLEC,
    TAG_OBJECT,
    TAG_SHORT_STR,
    TAG_TOMBSTONE,
    TAG_TUPLE,
    MUT_DICT,
    MUT_LIST,
    NONE_ENTRY,
    dict_key_hash,
    dict_key_rich_eq,
    dict_slot_count_for_stores,
    encode_short_str,
    int_value,
    is_mut_kind,
    make_bytearray,
    make_dict,
    make_list,
    make_none,
    make_null,
    make_set,
    mut_addr,
    mut_kind,
    obj_field_val_addr,
    pack_code_metadata,
    pack_ob_head,
)

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

    def _write_tagged(
        self, val_addr: int, tag: int, value: int, *, key: bool = False
    ) -> None:
        self._write(val_addr, value)
        tag_word = tag & 0xF
        if key and tag == TAG_CONTROL:
            # CONTROL keys preserve their secondary id beside the primary tag.
            tag_word |= (value & 0xF) << 4
        self._write(val_addr + 16, tag_word)

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
        return make_list(obj_addr)

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
    # v3 layout (relocatable table — mirrors pycore_defs.svh DICT section):
    #   obj + 0  : header { slot_count[63:0], used[63:0] }
    #   obj + 16 : { version[63:0], order_len[63:0] }
    #   obj + 32 : { order_ptr[63:0], table_ptr[63:0] }
    #   order + i*32 + 0/16 : key val/tag in insertion order
    #   table + i*64 + 0/16/32/48 : key val/tag, value val/tag
    # BUILD_MAP-style images allocate object, order buffer, then table.
    DICT_OBJ_BYTES = 48

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
        order = 0
        table = 0
        if slot_count:
            order = self._alloc(slot_count * 32)
            table = self._alloc(slot_count * 64)
            for i in range(slot_count):
                self._write(order + i * 32, 0)
                self._write(order + 16 + i * 32, 0)
            # Zero all slots (CONTROL+UNINIT is the all-zero empty sentinel).
            for i in range(slot_count):
                self._write(table + i * 64, 0)              # kval
                self._write(table + 16 + i * 64, 0)          # ktag
                self._write(table + 32 + i * 64, 0)          # vval
                self._write(table + 48 + i * 64, 0)          # vtag

        self._write(
            obj, ((slot_count & ((1 << 64) - 1)) << 64) | 0
        )  # used=0 for now
        self._write(obj + 16, 0)  # version=0, order_len=0
        self._write(
            obj + 32,
            ((order & ((1 << 64) - 1)) << 64)
            | (table & ((1 << 64) - 1)),
        )

        used = 0
        version = 0
        if slot_count:
            mask = slot_count - 1
            for (ktag, kval), (vtag, vval) in pairs:
                h = dict_key_hash(ktag, kval) & mask
                probes = 0
                idx = h
                while probes < slot_count:
                    ktag_addr = table + 16 + idx * 64
                    existing_tag_word = self.words.get(ktag_addr, 0)
                    existing_tag = existing_tag_word & 0xF
                    if existing_tag_word == 0:
                        self._write_tagged(
                            table + idx * 64, ktag, kval, key=True
                        )
                        self._write_tagged(table + 32 + idx * 64, vtag, vval)
                        self._write_tagged(order + used * 32, ktag, kval)
                        used += 1
                        version += 1
                        break
                    # Overwrite on rich key match (incl. INT/BOOL/FLOAT cross).
                    existing_val = self.words.get(table + idx * 64, 0)
                    if dict_key_rich_eq(ktag, kval, existing_tag, existing_val):
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
        self._write(
            obj + 16,
            ((version & ((1 << 64) - 1)) << 64)
            | (used & ((1 << 64) - 1)),
        )
        return make_dict(obj)

    # ---- SET ----
    # Element-only open addressing (see set_excore.md / pycore_defs.svh):
    #   obj + 0  : header { slot_count[63:0], used[63:0] }
    #   obj + 16 : { 64'd0, table_ptr[63:0] }
    #   table + i*32 + 0/16 : element val/tag
    SET_OBJ_BYTES = 32

    def alloc_set(
        self,
        elements: list[Tagged],
        slot_count: int | None = None,
    ) -> Tagged:
        n = len(elements)
        if slot_count is None:
            slot_count = dict_min_slots(n)
        if slot_count < 0 or (
            slot_count > 0 and (slot_count & (slot_count - 1)) != 0
        ):
            raise ValueError("slot_count must be 0 or a positive power of two")
        if slot_count > 0 and n >= slot_count:
            raise ValueError(
                f"set would fill table completely ({n} elems, {slot_count} slots)"
            )
        if slot_count == 0 and n > 0:
            raise ValueError("non-empty set requires slot_count > 0")

        obj = self._alloc(self.SET_OBJ_BYTES)
        table = 0
        if slot_count:
            table = self._alloc(slot_count * 32)
            for i in range(slot_count):
                self._write(table + i * 32, 0)
                self._write(table + 16 + i * 32, 0)

        self._write(obj, ((slot_count & ((1 << 64) - 1)) << 64) | 0)
        self._write(obj + 16, table & ((1 << 64) - 1))

        used = 0
        if slot_count:
            mask = slot_count - 1
            for etag, eval_ in elements:
                h = dict_key_hash(etag, eval_) & mask
                probes = 0
                idx = h
                while probes < slot_count:
                    existing_tag_word = self.words.get(
                        table + 16 + idx * 32, 0
                    )
                    existing_tag = existing_tag_word & 0xF
                    if existing_tag_word == 0:
                        self._write_tagged(
                            table + idx * 32, etag, eval_, key=True
                        )
                        used += 1
                        break
                    if existing_tag == TAG_TOMBSTONE:
                        idx = (idx + 1) & mask
                        probes += 1
                        continue
                    existing_val = self.words.get(table + idx * 32, 0)
                    if dict_key_rich_eq(etag, eval_, existing_tag, existing_val):
                        break  # duplicate
                    idx = (idx + 1) & mask
                    probes += 1
                else:
                    raise RuntimeError("set probe exhausted during image build")

        self._write(
            obj,
            ((slot_count & ((1 << 64) - 1)) << 64) | (used & ((1 << 64) - 1)),
        )
        return make_set(obj)

    # ---- CODE OBJECT ----
    def add_code_object(
        self,
        entry_slot: int,
        co_consts: Tagged,
        co_names: Tagged,
        co_varnames: Tagged,
        *,
        stacksize: int,
        nlocals: int,
        argcount: int,
        kwonlyargcount: int = 0,
        co_defaults: Tagged | None = None,
        co_kwdefaults: Tagged | None = None,
    ) -> Tagged:
        """Allocate a 224-byte code object (7 tagged-entry fields).

        field 0 : entry_slot  (INT) — imem slot index of the first code unit
        field 1 : co_consts   (TUPLE handle)
        field 2 : co_names    (TUPLE handle)
        field 3 : metadata    (INT) — packed
                  {kwonlyargcount, stacksize, nlocals, argcount}
        field 4 : co_defaults (TUPLE handle; empty ⇒ exact argc match)
        field 5 : co_varnames (TUPLE handle; local/argument names)
        field 6 : co_kwdefaults (MUT_DICT handle; empty ⇒ no kw-only defaults)
        """
        assert CODE_OBJECT_NFIELDS == 7
        assert co_consts[0] == TAG_TUPLE
        assert co_names[0] == TAG_TUPLE
        if co_varnames[0] != TAG_TUPLE:
            raise ValueError("co_varnames must be a TUPLE handle")
        if co_defaults is None:
            co_defaults = self.alloc_tuple([])
        if co_defaults[0] != TAG_TUPLE:
            raise ValueError("co_defaults must be a TUPLE handle")
        if co_kwdefaults is None:
            co_kwdefaults = self.alloc_dict([], slot_count=4)
        if not is_mut_kind(co_kwdefaults, MUT_DICT):
            raise ValueError("co_kwdefaults must be a MUT_DICT handle")
        addr = self._alloc(CODE_OBJECT_BYTES)
        fields: list[Tagged] = [
            (TAG_INT, int_value(entry_slot)),  # field 0
            co_consts,                         # field 1
            co_names,                          # field 2
            (
                TAG_INT,
                pack_code_metadata(
                    stacksize, nlocals, argcount, kwonlyargcount
                ),
            ),                                 # field 3
            co_defaults,                       # field 4
            co_varnames,                       # field 5
            co_kwdefaults,                     # field 6
        ]
        # Silence unused-import lint for field index constants (documented API).
        assert CODE_FIELD_ENTRY_SLOT == 0
        assert CODE_FIELD_CO_CONSTS == 1
        assert CODE_FIELD_CO_NAMES == 2
        assert CODE_FIELD_METADATA == 3
        assert CODE_FIELD_CO_DEFAULTS == 4
        assert CODE_FIELD_CO_VARNAMES == 5
        assert CODE_FIELD_CO_KWDEFAULTS == 6
        for i, (tag, val) in enumerate(fields):
            self._write_tagged(addr + i * 32, tag, val)
        return TAG_CODE_OBJECT, addr & ((1 << 64) - 1)

    # ---- General OBJECT substrate (PY_TAG_OBJECT + OBK_*) ----

    def _alloc_object(
        self,
        nbytes: int,
        kind: int,
        fields: list[Tagged],
        *,
        type_addr: int = 0,
        flags: int = 0,
    ) -> Tagged:
        """Allocate a general OBJECT with ob_head + tagged fields.

        Layout matches pycore_defs.svh: header at +0/+16, field *i* at
        ``obj_field_val_addr(obj, i)``.
        """
        if nbytes < 32 + 32 * len(fields):
            raise ValueError(
                f"object size {nbytes} too small for {len(fields)} fields"
            )
        addr = self._alloc(nbytes)
        self._write(addr, pack_ob_head(kind, flags, type_addr))
        # Self-tag at +16 preserves the 32-byte stride (tag word only).
        self._write(addr + 16, TAG_OBJECT & 0xF)
        for i, (tag, val) in enumerate(fields):
            self._write_tagged(obj_field_val_addr(addr, i), tag, val)
        return TAG_OBJECT, addr & ((1 << 64) - 1)

    def alloc_instance(
        self,
        *,
        type_addr: int = 0,
        idict: Tagged | None = None,
        flags: int = 0,
    ) -> Tagged:
        """OBK_INSTANCE: field0 = __dict__ (DICT handle)."""
        if idict is None:
            idict = self.alloc_dict([], slot_count=4)
        if not is_mut_kind(idict, MUT_DICT):
            raise ValueError("instance __dict__ must be a DICT handle")
        return self._alloc_object(
            OBJ_INSTANCE_BYTES,
            OBK_INSTANCE,
            [idict],
            type_addr=type_addr,
            flags=flags,
        )

    def alloc_type(
        self,
        tp_name: Tagged,
        *,
        tp_dict: Tagged | None = None,
        tp_base: Tagged | None = None,
        flags: int = 0,
    ) -> Tagged:
        """OBK_TYPE: field0=tp_dict, field1=tp_base, field2=tp_name."""
        if tp_dict is None:
            tp_dict = self.alloc_dict([], slot_count=4)
        if tp_base is None:
            tp_base = make_none()
        if not is_mut_kind(tp_dict, MUT_DICT):
            raise ValueError("tp_dict must be a DICT handle")
        if tp_base != NONE_ENTRY and tp_base[0] != TAG_OBJECT:
            raise ValueError("tp_base must be NONE or OBJECT")
        return self._alloc_object(
            OBJ_TYPE_BYTES,
            OBK_TYPE,
            [tp_dict, tp_base, tp_name],
            type_addr=0,
            flags=flags,
        )

    def alloc_bound_method(
        self,
        func: Tagged,
        self_obj: Tagged,
        *,
        flags: int = 0,
    ) -> Tagged:
        """OBK_BOUND_METHOD: field0=__func__, field1=__self__."""
        if func[0] != TAG_CODE_OBJECT:
            raise ValueError("bound-method __func__ must be CODE_OBJECT")
        return self._alloc_object(
            OBJ_BOUND_METHOD_BYTES,
            OBK_BOUND_METHOD,
            [func, self_obj],
            flags=flags,
        )

    def alloc_builtin(
        self,
        builtin_id: int,
        bound_self: Tagged | None = None,
        *,
        flags: int = 0,
    ) -> Tagged:
        """OBK_BUILTIN: field0=builtin_id (INT), field1=bound_self."""
        if bound_self is None:
            bound_self = make_null()
        return self._alloc_object(
            OBJ_BUILTIN_BYTES,
            OBK_BUILTIN,
            [(TAG_INT, int_value(builtin_id)), bound_self],
            flags=flags,
        )

    def alloc_bytearray(
        self,
        length: int,
        *,
        capacity: int | None = None,
        zero: bool = True,
        flags: int = 0,
    ) -> Tagged:
        """Allocate a MUT_BYTEARRAY handle over the legacy-compatible body.

        The body retains the OBK_BYTEARRAY field layout for existing firmware
        readers, but the externally visible handle is MUT_COLLEC/MUT_BYTEARRAY.
        """
        if length < 0:
            raise ValueError("bytearray length must be non-negative")
        if capacity is None:
            capacity = length
        if capacity < length:
            raise ValueError("bytearray capacity must be >= length")
        # Object first; buffer follows so the handle address is stable.
        addr = self._alloc(OBJ_BYTEARRAY_BYTES)
        buf_addr = 0
        if capacity > 0:
            # 16-byte align the buffer for dmem slot friendliness.
            pad = (16 - (self.ptr & 15)) & 15
            if pad:
                self._alloc(pad)
            alloc_bytes = (capacity + 15) & ~15
            buf_addr = self._alloc(alloc_bytes)
            if zero:
                for off in range(0, alloc_bytes, 16):
                    self._write(buf_addr + off, 0)
        self._write(addr, pack_ob_head(OBK_BYTEARRAY, flags, 0))
        self._write(addr + 16, TAG_OBJECT & 0xF)
        fields: list[Tagged] = [
            (TAG_INT, int_value(length)),
            (TAG_INT, int_value(buf_addr)),
            (TAG_INT, int_value(capacity)),
        ]
        for i, (tag, val) in enumerate(fields):
            self._write_tagged(obj_field_val_addr(addr, i), tag, val)
        return make_bytearray(addr)

    def alloc_exception(
        self,
        exc_type: Tagged,
        args: Tagged,
        *,
        flags: int = 0,
    ) -> Tagged:
        """OBK_EXCEPTION: field0=exc_type, field1=args (TUPLE)."""
        if args[0] != TAG_TUPLE:
            raise ValueError("exception args must be a TUPLE handle")
        return self._alloc_object(
            OBJ_EXCEPTION_BYTES,
            OBK_EXCEPTION,
            [exc_type, args],
            flags=flags,
        )

    def write_boot_record(
        self,
        module_code: Tagged,
        globals_dict: Tagged,
        builtins_dict: Tagged,
        addr: int = BOOT_RECORD_ADDR,
    ) -> None:
        """Write the three-pair boot record below the heap base.

        pair 0 : module code object handle (CODE_OBJECT)
        pair 1 : globals dict handle (DICT)
        pair 2 : builtins dict handle (DICT) at addr+64
        """
        if module_code[0] != TAG_CODE_OBJECT:
            raise ValueError("boot record pair 0 must be CODE_OBJECT")
        if not is_mut_kind(globals_dict, MUT_DICT):
            raise ValueError("boot record pair 1 must be DICT")
        if not is_mut_kind(builtins_dict, MUT_DICT):
            raise ValueError("boot record pair 2 must be DICT")
        if addr % 16 != 0:
            raise ValueError(f"boot record addr must be 16-byte aligned, got {addr:#x}")
        self._write_tagged(addr, module_code[0], module_code[1])
        self._write_tagged(addr + 32, globals_dict[0], globals_dict[1])
        self._write_tagged(addr + 64, builtins_dict[0], builtins_dict[1])

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
