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

import opcode as _opcode

import layout as L
from encoding import (  # noqa: E402
    FRAME_STACK_BASE as FRAME_BASE,
    SHORT_STR_MAX_BYTES,
    decode_short_string,
    heap_place,
    stracc_encode_units,
    stracc_kind_of_text,
)

READ, WRITE = 0, 1

# access classes
C_CONST = "const"           # co_consts element
C_NAME = "name"             # co_names element
C_GDICT = "globals"         # globals dict header/table/slots
C_BDICT = "builtins"        # builtins dict header/table/slots
C_CODE = "codeobj"          # code-object header fields
C_FRAME = "frame"           # call-frame push/pop slots
C_HEAP = "heap"             # user container payload (list/dict/tuple/obj)
C_STR = "str"               # STRACC payload / header in the object heap

# CPython 3.14 BINARY_OP opargs we model as STRACC.
NB_ADD = 0
NB_INPLACE_ADD = 13
NB_SUBSCR = 26
STR_WORD = 16               # one 128-bit dmem beat
SHORT_MAX = SHORT_STR_MAX_BYTES


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


@dataclass
class StrRef:
    """Shadow of a PyCore string: SHORT_STR has addr=None (payload in the handle)."""
    nchars: int
    nbytes: int
    kind: int
    addr: int | None
    text: str | None = None

    @property
    def is_short(self) -> bool:
        return self.addr is None


@dataclass
class StrIter:
    src: StrRef
    index: int = 0


@dataclass
class StrMeth:
    recv: StrRef
    name: str


def _str_from_text(lay: L.ImageLayout, text: str) -> StrRef:
    kind = stracc_kind_of_text(text)
    payload = stracc_encode_units(text, kind)
    nchars = len(text)
    nbytes = len(payload)
    if kind == 1 and nchars <= SHORT_MAX:
        return StrRef(nchars, nbytes, kind, None, text)
    addr = lay.str_intern.get(text)
    return StrRef(nchars, nbytes, kind, addr, text)


def _str_concat_text(a: StrRef, b: StrRef) -> str | None:
    if a.text is None or b.text is None:
        return None
    return a.text + b.text


def _payload_words(addr: int, nbytes: int, write: bool) -> list[Access]:
    nwords = (nbytes + STR_WORD - 1) // STR_WORD
    return [Access(addr + 16 + i * STR_WORD, write, C_STR) for i in range(nwords)]


def _header_acc(addr: int, write: bool) -> Access:
    return Access(addr, write, C_STR)


def _read_payload(src: StrRef) -> list[Access]:
    if src.is_short or src.addr is None or src.nbytes == 0:
        return []
    return _payload_words(src.addr, src.nbytes, False)


def _alloc_long(shadow: "_StrShadow", nchars: int, nbytes: int, kind: int,
                text: str | None) -> tuple[StrRef, list[Access]]:
    obj_bytes = 16 + ((nbytes + 15) & ~15)
    addr = heap_place(shadow.heap_ptr, obj_bytes)
    shadow.heap_ptr = addr + obj_bytes
    acc = [_header_acc(addr, True)] + _payload_words(addr, nbytes, True)
    return StrRef(nchars, nbytes, kind, addr, text), acc


def _result_kind(a: StrRef, b: StrRef) -> int:
    return max(a.kind, b.kind)


def _cmp_payload(a: StrRef, b: StrRef) -> list[Access]:
    """Tier-3 SA_CMP: both payloads, identity/fast-reject already filtered."""
    return _read_payload(a) + _read_payload(b)


def _char_at(src: StrRef, index: int) -> list[Access]:
    """SA_CHAR_AT: one 16-byte word at the indexed code unit (O(1))."""
    if src.is_short or src.addr is None:
        return []
    if index < 0 or index >= src.nchars:
        return _read_payload(src)[:1]
    off = index * src.kind
    word = off - (off % STR_WORD)
    return [Access(src.addr + 16 + word, False, C_STR)]


def _slice_range(src: StrRef, start: int, stop: int) -> tuple[StrRef | None, list[Access]]:
    if src.text is None:
        nchars = max(0, min(src.nchars, stop) - max(0, start))
        nbytes = nchars * src.kind
        acc = _read_payload(src)
        kind = src.kind
        text = None
    else:
        s = max(0, start)
        e = min(src.nchars, stop)
        if e < s:
            e = s
        text = src.text[s:e]
        kind = stracc_kind_of_text(text) if text else 1
        nchars = len(text)
        nbytes = len(stracc_encode_units(text, kind))
        # COPY reads the selected range; approximate as the covering words.
        acc = []
        if not src.is_short and src.addr is not None and nchars:
            first = s * src.kind
            last = max(first, e * src.kind - 1)
            w0 = first - (first % STR_WORD)
            w1 = last - (last % STR_WORD)
            w = w0
            while w <= w1:
                acc.append(Access(src.addr + 16 + w, False, C_STR))
                w += STR_WORD
    return StrRef(nchars, nbytes, kind, None, text), acc


class _StrShadow:
    """Per-trace shadow stack so STRACC accesses land at real heap addresses."""

    def __init__(self, lay: L.ImageLayout):
        self.lay = lay
        self.stack: list[object] = []
        self.frames: list[dict[int, object]] = [{}]
        self.heap_ptr = lay.heap_init_ptr

    def _pop(self):
        return self.stack.pop() if self.stack else None

    def _push(self, v):
        self.stack.append(v)

    def _tos(self):
        return self.stack[-1] if self.stack else None

    def _store_fast(self, idx, v):
        self.frames[-1][idx] = v

    def _load_fast(self, idx):
        return self.frames[-1].get(idx)

    def _enter(self):
        self.frames.append({})

    def _leave(self):
        if len(self.frames) > 1:
            self.frames.pop()


def _pair_fast_indices(arg: int) -> tuple[int, int]:
    """Decode LOAD_FAST_*_LOAD_FAST_* oparg: (a << 4) | b for a,b < 16."""
    if arg <= 0xFF:
        return (arg >> 4) & 0xF, arg & 0xF
    return (arg >> 8) & 0xFF, arg & 0xFF


_PAIR_LOAD = {
    "LOAD_FAST_LOAD_FAST",
    "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
    "LOAD_FAST_LOAD_FAST_BORROW",
    "LOAD_FAST_BORROW_LOAD_FAST",
}


def _stack_effect(name: str, arg: int) -> int | None:
    op = _opcode.opmap.get(name)
    if op is None:
        return None
    try:
        return _opcode.stack_effect(op, arg)
    except Exception:
        try:
            return _opcode.stack_effect(op)
        except Exception:
            return None


def _attr_name(lay: L.ImageLayout, cl, namei: int) -> str:
    kval = lay.words.get(L.tuple_val_addr(cl.names_base, namei), 0)
    ktag = lay.words.get(L.tuple_tag_addr(cl.names_base, namei), 0) & 0xF
    # SHORT_STR names: inline Latin-1/UTF-8 bytes in the handle.
    if ktag == 0b0111:
        try:
            return decode_short_string(kval).decode("latin-1")
        except Exception:
            return ""
    if ktag == 0b1000:
        h = kval
        # intern reverse-lookup by address
        addr = h & 0xFFFFFFFF
        for text, a in lay.str_intern.items():
            if a == addr:
                return text
    return ""


def _materialize_result(shadow: _StrShadow, nchars: int, nbytes: int, kind: int,
                        text: str | None) -> tuple[StrRef, list[Access]]:
    if kind == 1 and nchars <= SHORT_MAX:
        return StrRef(nchars, nbytes, kind, None, text), []
    return _alloc_long(shadow, nchars, nbytes, kind, text)


def _str_step(shadow: _StrShadow, lay: L.ImageLayout, st, cl, codes,
              next_name: str) -> list[Access]:
    """Append STRACC dmem accesses for one retired opcode; keep the shadow aligned."""
    name = st.opname
    extra: list[Access] = []

    def apply_effect_unknown():
        eff = _stack_effect(name, st.arg)
        if eff is None:
            return
        if eff < 0:
            for _ in range(-eff):
                shadow._pop()
        elif eff > 0:
            for _ in range(eff):
                shadow._push(None)
        # eff == 0: no change. For replace (pop N push M) stack_effect is net;
        # net-zero ops that still rotate TOS are handled by name below.

    if name == "LOAD_CONST":
        co = codes.get(st.code_id)
        val = None
        if co is not None and 0 <= st.arg < len(co.co_consts):
            val = co.co_consts[st.arg]
        if isinstance(val, str):
            shadow._push(_str_from_text(lay, val))
        elif isinstance(val, int) and not isinstance(val, bool):
            shadow._push(val)
        elif isinstance(val, slice):
            shadow._push(val)
        else:
            shadow._push(None)
        return extra

    if name == "LOAD_SMALL_INT":
        shadow._push(st.arg)
        return extra

    if name in _PAIR_LOAD:
        a, b = _pair_fast_indices(st.arg)
        shadow._push(shadow._load_fast(a))
        shadow._push(shadow._load_fast(b))
        return extra

    if name in ("LOAD_FAST", "LOAD_FAST_BORROW", "LOAD_FAST_CHECK"):
        shadow._push(shadow._load_fast(st.arg))
        return extra

    if name in ("STORE_FAST", "STORE_FAST_STORE_FAST"):
        if name == "STORE_FAST":
            shadow._store_fast(st.arg, shadow._pop())
        else:
            apply_effect_unknown()
        return extra

    if name == "DELETE_FAST":
        shadow.frames[-1].pop(st.arg, None)
        return extra

    if name in ("LOAD_GLOBAL", "LOAD_NAME", "LOAD_COMMON_CONSTANT"):
        npush = _stack_effect(name, st.arg)
        if npush is None or npush <= 0:
            npush = 1
        for _ in range(npush):
            shadow._push(None)
        return extra

    if name == "PUSH_NULL":
        shadow._push(None)
        return extra

    if name in ("STORE_NAME", "STORE_GLOBAL"):
        shadow._pop()
        return extra

    if name == "POP_TOP":
        shadow._pop()
        return extra

    if name == "COPY":
        idx = st.arg
        if idx and len(shadow.stack) >= idx:
            shadow._push(shadow.stack[-idx])
        else:
            shadow._push(None)
        return extra

    if name == "SWAP":
        idx = st.arg
        if idx and len(shadow.stack) > idx:
            shadow.stack[-1], shadow.stack[-idx] = shadow.stack[-idx], shadow.stack[-1]
        return extra

    if name == "GET_ITER":
        src = shadow._pop()
        if isinstance(src, StrRef):
            shadow._push(StrIter(src, 0))
        else:
            shadow._push(None)
        return extra

    if name == "FOR_ITER":
        it = shadow._tos()
        if next_name == "END_FOR":
            return extra
        if isinstance(it, StrIter):
            extra += _char_at(it.src, it.index)
            ch = None
            if it.src.text is not None and it.index < it.src.nchars:
                ch = _str_from_text(lay, it.src.text[it.index])
            else:
                ch = StrRef(1, it.src.kind, it.src.kind, None, None)
            it.index += 1
            shadow._push(ch)
        else:
            shadow._push(None)
        return extra

    if name == "LOAD_ATTR":
        obj = shadow._pop()
        namei = st.arg >> 1
        attr = _attr_name(lay, cl, namei) if cl is not None else ""
        eff = _stack_effect(name, st.arg)
        npush = (eff + 1) if eff is not None else 1
        if isinstance(obj, StrRef) and attr:
            shadow._push(StrMeth(obj, attr))
            pushed = 1
            while pushed < npush:
                shadow._push(obj)
                pushed += 1
        else:
            for _ in range(max(npush, 1)):
                shadow._push(None)
        return extra

    if name.startswith("CALL"):
        argc = st.arg
        args = [shadow._pop() for _ in range(argc)]
        args.reverse()
        # 3.14 CALL also pops the callable and the self/NULL slot.
        self_or_null = shadow._pop()
        callable_v = shadow._pop()
        meth = callable_v if isinstance(callable_v, StrMeth) else (
            self_or_null if isinstance(self_or_null, StrMeth) else None)
        recv = meth.recv if meth else next((a for a in args if isinstance(a, StrRef)), None)
        result: object = None
        if meth is not None and meth.name in (
                "find", "rfind", "index", "rindex", "count",
                "startswith", "endswith"):
            extra += _read_payload(meth.recv)
            needle = args[0] if args and isinstance(args[0], StrRef) else None
            if needle is not None:
                extra += _read_payload(needle)
        elif meth is not None and meth.name in ("join",):
            extra += _read_payload(meth.recv)
        elif recv is not None and meth is not None and meth.name in (
                "upper", "lower", "swapcase", "strip", "lstrip", "rstrip",
                "replace", "split", "rsplit"):
            extra += _read_payload(recv)
            if recv.nchars:
                nchars, nbytes, kind, text = recv.nchars, recv.nbytes, recv.kind, recv.text
                result, wacc = _materialize_result(shadow, nchars, nbytes, kind, text)
                extra += wacc
        if st.enters_frame:
            shadow._enter()
            # Arguments become callee locals 0..argc-1 (positional).
            for i, a in enumerate(args):
                shadow._store_fast(i, a)
        shadow._push(result)
        return extra

    if name.startswith("RETURN"):
        ret = shadow._pop()
        if st.pops_frame:
            shadow._leave()
        shadow._push(ret)
        return extra

    if name == "COMPARE_OP":
        b = shadow._pop()
        a = shadow._pop()
        if isinstance(a, StrRef) and isinstance(b, StrRef):
            # EQ/NE: identity and (hash, nbytes, nchars) live in the handle.
            # Distinct LONG objects with matching meta pay SA_CMP.
            same_id = (a.addr is not None and a.addr == b.addr)
            same_meta = (a.nbytes == b.nbytes and a.nchars == b.nchars
                         and a.kind == b.kind)
            if not a.is_short and not b.is_short and not same_id and same_meta:
                extra += _cmp_payload(a, b)
        shadow._push(None)
        return extra

    if name == "CONTAINS_OP":
        # CONTAINS_OP: TOS1 in TOS  →  pop container, then key.
        container = shadow._pop()
        key = shadow._pop()
        if isinstance(container, StrRef):
            extra += _read_payload(container)
            if isinstance(key, StrRef):
                extra += _read_payload(key)
        shadow._push(None)
        return extra

    if name == "BINARY_SLICE":
        stop = shadow._pop()
        start = shadow._pop()
        src = shadow._pop()
        if isinstance(src, StrRef):
            s = 0 if not isinstance(start, int) else max(0, start)
            e = src.nchars if not isinstance(stop, int) else stop
            tmp, racc = _slice_range(src, s, e)
            extra += racc
            if tmp is not None:
                res, wacc = _materialize_result(
                    shadow, tmp.nchars, tmp.nbytes, tmp.kind, tmp.text)
                extra += wacc
                shadow._push(res)
            else:
                shadow._push(None)
        else:
            shadow._push(None)
        return extra

    if name == "BINARY_OP":
        b = shadow._pop()
        a = shadow._pop()
        if st.arg in (NB_ADD, NB_INPLACE_ADD) and isinstance(a, int) and isinstance(b, int):
            shadow._push(a + b)
            return extra
        if st.arg in (10, 23) and isinstance(a, int) and isinstance(b, int):
            # NB_SUBTRACT / NB_INPLACE_SUBTRACT
            shadow._push(a - b)
            return extra
        if st.arg in (NB_ADD, NB_INPLACE_ADD) and isinstance(a, StrRef) and isinstance(b, StrRef):
            extra += _read_payload(a) + _read_payload(b)
            text = _str_concat_text(a, b)
            nchars = a.nchars + b.nchars
            kind = _result_kind(a, b)
            nbytes = nchars * kind if text is None else len(
                stracc_encode_units(text, stracc_kind_of_text(text)))
            if text is not None:
                kind = stracc_kind_of_text(text)
            res, wacc = _materialize_result(shadow, nchars, nbytes, kind, text)
            extra += wacc
            shadow._push(res)
            return extra
        if st.arg == NB_SUBSCR and isinstance(a, StrRef):
            if isinstance(b, slice):
                s = 0 if not isinstance(b.start, int) else max(0, b.start)
                e = a.nchars if not isinstance(b.stop, int) else b.stop
                tmp, racc = _slice_range(a, s, e)
                extra += racc
                res, wacc = _materialize_result(
                    shadow, tmp.nchars, tmp.nbytes, tmp.kind, tmp.text)
                extra += wacc
                shadow._push(res)
                return extra
            extra += _char_at(a, b if isinstance(b, int) else 0)
            ch = None
            if a.text is not None and isinstance(b, int) and 0 <= b < a.nchars:
                ch = _str_from_text(lay, a.text[b])
            else:
                ch = StrRef(1, a.kind, a.kind, None, None)
            shadow._push(ch)
            return extra
        shadow._push(None)
        return extra

    if name in ("BUILD_STRING",):
        n = st.arg
        parts = [shadow._pop() for _ in range(n)]
        parts.reverse()
        strs = [p for p in parts if isinstance(p, StrRef)]
        extra += [acc for s in strs for acc in _read_payload(s)]
        if strs:
            nchars = sum(s.nchars for s in strs)
            kind = max((s.kind for s in strs), default=1)
            texts = [s.text for s in strs]
            text = "".join(texts) if all(t is not None for t in texts) else None
            nbytes = nchars * kind if text is None else len(
                stracc_encode_units(text, stracc_kind_of_text(text) if text else 1))
            if text is not None:
                kind = stracc_kind_of_text(text)
            res, wacc = _materialize_result(shadow, nchars, nbytes, kind, text)
            extra += wacc
            shadow._push(res)
        else:
            shadow._push(None)
        return extra

    # Default: apply net stack_effect with unknown values. Net-zero ops
    # (jumps, CACHE, NOP, …) leave the shadow alone.
    eff = _stack_effect(name, st.arg)
    if eff is None:
        return extra
    if name in ("CACHE", "EXTENDED_ARG", "NOP", "RESUME", "NOT_TAKEN",
                "JUMP_FORWARD", "JUMP_BACKWARD", "JUMP_BACKWARD_NO_INTERRUPT",
                "END_FOR", "POP_ITER"):
        return extra
    if name.startswith("POP_JUMP") or name.startswith("JUMP"):
        if eff < 0:
            for _ in range(-eff):
                shadow._pop()
        return extra
    if eff < 0:
        for _ in range(-eff):
            shadow._pop()
    elif eff > 0:
        for _ in range(eff):
            shadow._push(None)
    return extra


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
    shadow = _StrShadow(lay)

    for i, st in enumerate(steps):
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
        next_name = steps[i + 1].opname if i + 1 < len(steps) else ""

        if cl is None:
            acc += _str_step(shadow, lay, st, None, codes, next_name)
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

        acc += _str_step(shadow, lay, st, cl, codes, next_name)
        out.append(OpCost(name, st.code_id, slots, acc))
    return out


def _name_key(lay, cl, namei):
    kval = lay.words.get(L.tuple_val_addr(cl.names_base, namei), 0)
    ktag = lay.words.get(L.tuple_tag_addr(cl.names_base, namei), 0) & 0xF
    return ktag, kval


def _frame_addr(depth: int, slot: int) -> int:
    return FRAME_BASE + depth * 32 + slot * 16
