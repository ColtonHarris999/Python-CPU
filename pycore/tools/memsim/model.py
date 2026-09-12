"""Expand a retired-opcode trace into the dmem/imem access stream PyCore issues.

Access counts and ordering follow the as-built RTL:
  * co_consts / co_names / co_varnames / co_defaults are TUPLEs: element i is
    32 bytes, val at base+32i, tag at base+32i+16 -> two 128-bit dmem reads.
  * A code object is 8 tagged fields, 32 bytes apiece (256 B total).
  * A dict slot is 64 bytes: kval, ktag, vval, vtag (four 128-bit words).
  * Every dependent dmem access costs 3 core cycles (issue, bank, observe);
    see pycore_core.sv S_CONTAINER handshake.

Opcodes with no modelled dmem traffic emit none. That understates total
traffic, so every cache saving reported here is a lower bound.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import layout as L
from encoding import FRAME_STACK_BASE as FRAME_BASE

READ, WRITE = 0, 1

# access classes
C_CONST = "const"           # co_consts element
C_NAME = "name"             # co_names element
C_GDICT = "globals"         # globals dict header/table/slots
C_BDICT = "builtins"        # builtins dict header/table/slots
C_CODE = "codeobj"          # code-object header fields
C_FRAME = "frame"           # call-frame push/pop slots
C_HEAP = "heap"             # user container payload (list/dict/tuple/obj)


@dataclass
class Access:
    addr: int
    write: bool
    cls: str


@dataclass
class OpCost:
    opname: str
    code_id: int
    slots: int                      # imem slots fetched (1 + caches + ext_args)
    accesses: list[Access] = field(default_factory=list)


CACHES = None  # set by caller


def _tuple_elem(base: int, idx: int, cls: str) -> list[Access]:
    return [Access(L.tuple_val_addr(base, idx), False, cls),
            Access(L.tuple_tag_addr(base, idx), False, cls)]


class LiveDict:
    """Mutable shadow of an image dict so runtime STORE_NAME inserts are seen."""

    def __init__(self, lay, obj, tbl, slots, cls):
        self.lay, self.obj, self.tbl, self.slots, self.cls = lay, obj, tbl, slots, cls
        self.occupied: dict[int, tuple[int, int]] = {}
        if slots:
            for i in range(slots):
                w = lay.words.get(L.dict_ktag_addr(tbl, i), 0)
                if w:
                    self.occupied[i] = (w & 0xF,
                                        lay.words.get(L.dict_kval_addr(tbl, i), 0))

    def _probe_seq(self, ktag, kval):
        if not self.slots:
            return [], False
        mask = self.slots - 1
        idx = L.dict_key_hash(ktag, kval) & mask
        seq = []
        for _ in range(self.slots):
            seq.append(idx)
            cur = self.occupied.get(idx)
            if cur is None:
                return seq, False
            if cur == (ktag, kval):
                return seq, True
            idx = (idx + 1) & mask
        return seq, False

    def lookup(self, ktag, kval):
        """Accesses issued by a probe: header, table_ptr, then per slot."""
        acc = [Access(self.obj, False, self.cls),
               Access(L.dict_table_ptr_addr(self.obj), False, self.cls)]
        seq, found = self._probe_seq(ktag, kval)
        for idx in seq:
            acc.append(Access(L.dict_ktag_addr(self.tbl, idx), False, self.cls))
            if idx not in self.occupied:
                break
            acc.append(Access(L.dict_kval_addr(self.tbl, idx), False, self.cls))
            if self.occupied[idx] == (ktag, kval):
                acc.append(Access(L.dict_vval_addr(self.tbl, idx), False, self.cls))
                acc.append(Access(L.dict_vtag_addr(self.tbl, idx), False, self.cls))
                break
        return acc, found

    def store(self, ktag, kval):
        acc, found = self.lookup(ktag, kval)
        seq, _ = self._probe_seq(ktag, kval)
        idx = seq[-1] if seq else 0
        if not found:
            self.occupied[idx] = (ktag, kval)
            for f in (L.dict_kval_addr, L.dict_ktag_addr):
                acc.append(Access(f(self.tbl, idx), True, self.cls))
        for f in (L.dict_vval_addr, L.dict_vtag_addr):
            acc.append(Access(f(self.tbl, idx), True, self.cls))
        acc.append(Access(self.obj, True, self.cls))
        return acc


def expand(lay: L.ImageLayout, steps, codes, caches: dict[str, int]) -> list[OpCost]:
    out: list[OpCost] = []
    stack: list[int] = []          # caller code id per live python frame
    g = LiveDict(lay, lay.globals_obj, lay.globals_table, lay.globals_slots, C_GDICT)
    b = LiveDict(lay, lay.builtins_obj, lay.builtins_table, lay.builtins_slots, C_BDICT)

    for st in steps:
        cl = lay.code_layout.get(st.code_id)
        name = st.opname
        ncache = caches.get(name, 0)
        ext = 0
        a = st.arg
        while a > 0xFF:
            ext += 1
            a >>= 8
        slots = 1 + ncache + ext
        acc: list[Access] = []

        if cl is None:
            out.append(OpCost(name, st.code_id, slots, acc))
            continue

        if name == "LOAD_CONST":
            acc += _tuple_elem(cl.consts_base, st.arg, C_CONST)

        elif name in ("LOAD_GLOBAL", "LOAD_NAME"):
            namei = (st.arg >> 1) if name == "LOAD_GLOBAL" else st.arg
            acc += _tuple_elem(cl.names_base, namei, C_NAME)
            ktag, kval = _name_key(lay, cl, namei)
            ga, found = g.lookup(ktag, kval)
            acc += ga
            if not found:
                ba, _ = b.lookup(ktag, kval)
                acc += ba

        elif name in ("STORE_NAME", "STORE_GLOBAL"):
            acc += _tuple_elem(cl.names_base, st.arg, C_NAME)
            ktag, kval = _name_key(lay, cl, st.arg)
            acc += g.store(ktag, kval)

        elif name.startswith("CALL") and st.enters_frame:
            ccl = lay.code_layout.get(st.callee_id)
            if ccl is not None:
                for f in (L.F_ENTRY_SLOT, L.F_CONSTS, L.F_NAMES,
                          L.F_META, L.F_DEFAULTS):
                    acc.append(Access(L.code_field_val_addr(ccl.code_addr, f),
                                      False, C_CODE))
            acc.append(Access(_frame_addr(len(stack), 0), True, C_FRAME))
            acc.append(Access(_frame_addr(len(stack), 1), True, C_FRAME))
            stack.append(st.code_id)

        elif name.startswith("RETURN") and st.pops_frame and stack:
            caller = stack.pop()
            acc.append(Access(_frame_addr(len(stack), 1), False, C_FRAME))
            acc.append(Access(_frame_addr(len(stack), 0), False, C_FRAME))
            ccl = lay.code_layout.get(caller)
            if ccl is not None:
                acc.append(Access(L.code_field_val_addr(ccl.code_addr, L.F_CONSTS),
                                  False, C_CODE))
                acc.append(Access(L.code_field_val_addr(ccl.code_addr, L.F_NAMES),
                                  False, C_CODE))

        out.append(OpCost(name, st.code_id, slots, acc))
    return out


def _name_key(lay, cl, namei):
    kval = lay.words.get(L.tuple_val_addr(cl.names_base, namei), 0)
    ktag = lay.words.get(L.tuple_tag_addr(cl.names_base, namei), 0) & 0xF
    return ktag, kval


def _frame_addr(depth: int, slot: int) -> int:
    return FRAME_BASE + depth * 32 + slot * 16
