"""Python model of the String Accelerator (planning/string_accelerator_plan.md).

Standalone: it owns a byte-addressable dmem image, packs SHORT/LONG handles,
and implements the P5a engines (COPY, COMPARE, SEARCH, CHAR_AT, ITER_NEXT,
HASH). The RTL in pycore_str_accel.sv is the hardware of this spec. CPython
3.14 is the oracle for string *values*; hashes and SHORT/LONG classification
are this model's.
"""

from __future__ import annotations

from dataclasses import dataclass

from encoding import (
    CTL_NONE,
    HEAP_BASE,
    HEAP_LIMIT,
    SA_CHAR_AT,
    SA_CMP,
    SA_CONCAT,
    SA_CONTAINS,
    SA_COUNT,
    SA_ENDSWITH,
    SA_FIND,
    SA_HASH,
    SA_ITER_NEXT,
    SA_PAD,
    SA_PAD_BOTH,
    SA_PAD_LEFT,
    SA_PAD_RIGHT,
    SA_REPEAT,
    SA_RFIND,
    SA_SEARCH,
    SA_SLICE,
    SA_STARTSWITH,
    SHORT_STR_MAX_BYTES,
    STRACC_FLAG_INTERNED,
    TAG_BOOL,
    TAG_CONTROL,
    TAG_INT,
    TAG_LONG_STR,
    TAG_SHORT_STR,
    VAL_MASK,
    decode_short_string,
    encode_short_string,
    heap_place,
    stracc_case_flags,
    stracc_content_hash,
    stracc_decode_units,
    stracc_encode_units,
    stracc_kind_of_text,
    stracc_pack_header,
    stracc_pack_long_handle,
    stracc_unpack_long_handle,
)

TRAP_TYPE = 1
TRAP_MEM_FAULT = 7


@dataclass
class AccelResult:
    tag: int
    value: int
    heap_ptr: int
    trap: bool = False
    trap_code: int = 0

    @property
    def entry(self) -> tuple[int, int]:
        return self.tag, self.value

    def signed_int(self) -> int:
        v = self.value & VAL_MASK
        if v >= (1 << 127):
            v -= 1 << 128
        return v


class DMem:
    """16-byte-word dmem, matching the RAM CPU port."""

    def __init__(self) -> None:
        self.words: dict[int, int] = {}

    def read_word(self, addr: int) -> int:
        return self.words.get(addr & ~15, 0)

    def write_word(self, addr: int, data: int, strb: int = 0xFFFF) -> None:
        a = addr & ~15
        old = self.words.get(a, 0)
        merged = 0
        for b in range(16):
            byte = ((data if (strb >> b) & 1 else old) >> (8 * b)) & 0xFF
            merged |= byte << (8 * b)
        self.words[a] = merged & VAL_MASK

    def write_bytes(self, addr: int, payload: bytes) -> None:
        for i, byte in enumerate(payload):
            a = (addr + i) & ~15
            off = (addr + i) & 15
            word = self.words.get(a, 0)
            word &= ~(0xFF << (8 * off))
            word |= byte << (8 * off)
            self.words[a] = word

    def read_bytes(self, addr: int, n: int) -> bytes:
        out = bytearray(n)
        for i in range(n):
            a = (addr + i) & ~15
            off = (addr + i) & 15
            out[i] = (self.words.get(a, 0) >> (8 * off)) & 0xFF
        return bytes(out)


@dataclass
class StrView:
    tag: int
    nchars: int
    nbytes: int
    kind: int
    digest: int
    flags: int
    addr: int
    short_bytes: bytes = b""
    interned: bool = False

    @property
    def is_short(self) -> bool:
        return self.tag == TAG_SHORT_STR

    def units(self, mem: DMem) -> list[int]:
        if self.is_short:
            return list(self.short_bytes)
        payload = mem.read_bytes(self.addr + 16, self.nbytes)
        width = self.kind
        out = []
        for i in range(0, self.nbytes, width):
            out.append(int.from_bytes(payload[i:i + width], "little"))
        return out

    def text(self, mem: DMem) -> str:
        if self.is_short:
            return self.short_bytes.decode("latin-1")
        payload = mem.read_bytes(self.addr + 16, self.nbytes)
        return stracc_decode_units(payload, self.kind)


def _sign64(n: int) -> int:
    n &= (1 << 64) - 1
    if n & (1 << 63):
        return n - (1 << 64)
    return n


def _int_val(tag: int, value: int) -> int | None:
    if tag == TAG_INT:
        return _sign64(value)
    if tag == TAG_BOOL:
        return value & 1
    return None


def _is_none(tag: int, value: int) -> bool:
    return tag == TAG_CONTROL and (value & 0xF) == CTL_NONE


def kind_of_unit(unit: int) -> int:
    if unit <= 0xFF:
        return 1
    if unit <= 0xFFFF:
        return 2
    return 4


def _is_string(tag: int) -> bool:
    return tag in (TAG_SHORT_STR, TAG_LONG_STR)


def decode_str(tag: int, value: int, mem: DMem) -> StrView:
    if tag == TAG_SHORT_STR:
        data = decode_short_string(value)
        digest = stracc_content_hash(data)
        flags = stracc_case_flags(list(data))
        return StrView(
            tag=tag,
            nchars=len(data),
            nbytes=len(data),
            kind=1,
            digest=digest,
            flags=flags,
            addr=0,
            short_bytes=data,
        )
    if tag != TAG_LONG_STR:
        raise TypeError("not a string")
    h = stracc_unpack_long_handle(value)
    return StrView(
        tag=tag,
        nchars=h["nchars"],
        nbytes=h["nbytes"],
        kind=h["kind"],
        digest=h["hash"],
        flags=h["flags"],
        addr=h["addr"],
        interned=bool(h["flags"] & STRACC_FLAG_INTERNED),
    )


def empty_short() -> tuple[int, int]:
    return TAG_SHORT_STR, encode_short_string(b"")


def pack_result_from_units(
    units: list[int],
    kind: int,
    mem: DMem,
    heap_ptr: int,
    heap_limit: int,
    flags: int | None = None,
) -> AccelResult:
    nchars = len(units)
    nbytes = nchars * kind
    if flags is None:
        flags = stracc_case_flags(units)
    payload = b"".join(int.to_bytes(u, kind, "little") for u in units)
    digest = stracc_content_hash(payload)
    # Canonical invariant: SHORT iff kind==1 and nchars<=15.
    if kind == 1 and nchars <= SHORT_STR_MAX_BYTES:
        return AccelResult(TAG_SHORT_STR, encode_short_string(payload), heap_ptr)
    obj_bytes = 16 + ((nbytes + 15) & ~15)
    place = heap_place(heap_ptr, obj_bytes)
    end = place + obj_bytes
    if end > heap_limit:
        return AccelResult(0, 0, heap_ptr, True, TRAP_MEM_FAULT)
    header = stracc_pack_header(nchars, nbytes, kind, digest, flags)
    mem.write_word(place, header)
    mem.write_bytes(place + 16, payload)
    handle = stracc_pack_long_handle(place, nchars, nbytes, kind, digest, flags)
    return AccelResult(TAG_LONG_STR, handle, end)


class StrAccel:
    def __init__(self, heap_limit: int = HEAP_LIMIT) -> None:
        self.mem = DMem()
        self.heap_limit = heap_limit
        self.intern: dict[tuple[int, bytes], int] = {}

    def alloc_str(self, text: str, heap_ptr: int, interned: bool = False) -> AccelResult:
        kind = stracc_kind_of_text(text)
        units = [ord(c) for c in text]
        flags = stracc_case_flags(units)
        if interned:
            flags |= STRACC_FLAG_INTERNED
            key = (kind, stracc_encode_units(text, kind))
            existing = self.intern.get(key)
            if existing is not None:
                payload = key[1]
                digest = stracc_content_hash(payload)
                handle = stracc_pack_long_handle(
                    existing, len(text), len(payload), kind, digest, flags
                )
                if kind == 1 and len(text) <= SHORT_STR_MAX_BYTES:
                    return AccelResult(
                        TAG_SHORT_STR, encode_short_string(payload), heap_ptr
                    )
                return AccelResult(TAG_LONG_STR, handle, heap_ptr)
        result = pack_result_from_units(
            units, kind, self.mem, heap_ptr, self.heap_limit, flags
        )
        if interned and not result.trap and result.tag == TAG_LONG_STR:
            h = stracc_unpack_long_handle(result.value)
            self.intern[(kind, stracc_encode_units(text, kind))] = h["addr"]
        return result

    def exec(
        self,
        op: int,
        var: int,
        a: tuple[int, int],
        b: tuple[int, int],
        c: tuple[int, int],
        heap_ptr: int,
    ) -> AccelResult:
        if op == SA_CONCAT:
            return self._concat(a, b, heap_ptr)
        if op == SA_REPEAT:
            return self._repeat(a, b, heap_ptr)
        if op == SA_SLICE:
            return self._slice(a, b, c, heap_ptr)
        if op == SA_PAD:
            return self._pad(a, b, c, var, heap_ptr)
        if op == SA_CMP:
            return self._cmp(a, b, heap_ptr)
        if op == SA_SEARCH:
            return self._search(a, b, c, var, heap_ptr)
        if op == SA_HASH:
            return self._hash(a, heap_ptr)
        if op in (SA_CHAR_AT, SA_ITER_NEXT):
            return self._char_at(a, b, heap_ptr, iter_next=(op == SA_ITER_NEXT))
        return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)

    def _need_str(self, entry: tuple[int, int], heap_ptr: int) -> StrView | AccelResult:
        tag, value = entry
        if not _is_string(tag):
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        return decode_str(tag, value, self.mem)

    def _concat(self, a, b, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        sb = self._need_str(b, heap_ptr)
        if isinstance(sb, AccelResult):
            return sb
        if sa.nchars == 0:
            return AccelResult(sb.tag, b[1], heap_ptr)
        if sb.nchars == 0:
            return AccelResult(sa.tag, a[1], heap_ptr)
        kind = max(sa.kind, sb.kind)
        units = sa.units(self.mem) + sb.units(self.mem)
        return pack_result_from_units(units, kind, self.mem, heap_ptr, self.heap_limit)

    def _repeat(self, a, b, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        n = _int_val(*b)
        if n is None:
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        if n <= 0 or sa.nchars == 0:
            return AccelResult(*empty_short(), heap_ptr)
        if n == 1:
            return AccelResult(sa.tag, a[1], heap_ptr)
        units = sa.units(self.mem) * n
        return pack_result_from_units(
            units, sa.kind, self.mem, heap_ptr, self.heap_limit
        )

    def _slice(self, a, b, c, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        start = None if _is_none(*b) else _int_val(*b)
        stop = None if _is_none(*c) else _int_val(*c)
        if (not _is_none(*b) and start is None) or (not _is_none(*c) and stop is None):
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        units = sa.units(self.mem)[slice(start, stop)]
        if not units:
            # Canonical invariant: the empty string is always SHORT.
            return AccelResult(*empty_short(), heap_ptr)
        # CPython slice keeps the source kind (does not re-compact).
        return pack_result_from_units(
            units, sa.kind, self.mem, heap_ptr, self.heap_limit
        )

    def _pad(self, a, b, c, var: int, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        width = _int_val(*b)
        if width is None:
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        if width <= sa.nchars:
            return AccelResult(sa.tag, a[1], heap_ptr)
        fill = 0x20
        if _is_string(c[0]):
            sc = decode_str(c[0], c[1], self.mem)
            if sc.nchars != 1:
                return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
            fill = sc.units(self.mem)[0]
        elif not _is_none(*c) and c[0] != TAG_CONTROL:
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        pad = width - sa.nchars
        if var == SA_PAD_LEFT:
            left, right = pad, 0
        elif var == SA_PAD_RIGHT:
            left, right = 0, pad
        else:
            left = pad // 2
            right = pad - left
        kind = sa.kind if fill <= (0xFF if sa.kind == 1 else 0xFFFF if sa.kind == 2 else 0x10FFFF) else (
            2 if fill <= 0xFFFF else 4
        )
        if fill > 0xFF and kind < 2:
            kind = 2
        if fill > 0xFFFF:
            kind = 4
        units = [fill] * left + sa.units(self.mem) + [fill] * right
        return pack_result_from_units(units, kind, self.mem, heap_ptr, self.heap_limit)

    def _cmp(self, a, b, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        sb = self._need_str(b, heap_ptr)
        if isinstance(sb, AccelResult):
            return sb
        if sa.tag == TAG_LONG_STR and sb.tag == TAG_LONG_STR and sa.addr == sb.addr:
            return AccelResult(TAG_INT, 0, heap_ptr)
        if (
            sa.digest != sb.digest
            or sa.nbytes != sb.nbytes
            or sa.nchars != sb.nchars
            or sa.kind != sb.kind
        ) and sa.nchars == sb.nchars and sa.kind == sb.kind and sa.nbytes == sb.nbytes:
            # hashes differ with equal length/kind — still must content-compare
            # if we want equality of distinct objects. Fast reject is only a
            # definite *inequality* when we then look at units.
            pass
        ua, ub = sa.units(self.mem), sb.units(self.mem)
        n = min(len(ua), len(ub))
        rel = 0
        for i in range(n):
            if ua[i] != ub[i]:
                rel = -1 if ua[i] < ub[i] else 1
                break
        if rel == 0:
            if len(ua) < len(ub):
                rel = -1
            elif len(ua) > len(ub):
                rel = 1
        val = rel & VAL_MASK
        if rel < 0:
            val = (rel + (1 << 128)) & VAL_MASK
        return AccelResult(TAG_INT, val, heap_ptr)

    def _search(self, a, b, c, var: int, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        sb = self._need_str(b, heap_ptr)
        if isinstance(sb, AccelResult):
            return sb
        hay = sa.units(self.mem)
        needle = sb.units(self.mem)
        start = 0
        end = sa.nchars
        if not _is_none(*c):
            s = _int_val(*c)
            if s is None:
                return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
            start = s if s >= 0 else max(0, sa.nchars + s)
        # Kind reject: needle has a code point the haystack kind cannot hold.
        if sb.kind > sa.kind and sb.nchars > 0:
            return self._search_miss(var, heap_ptr)
        if sb.nchars == 0:
            if var == SA_FIND:
                return AccelResult(TAG_INT, start, heap_ptr)
            if var == SA_RFIND:
                return AccelResult(TAG_INT, end, heap_ptr)
            if var == SA_COUNT:
                return AccelResult(TAG_INT, end - start + 1, heap_ptr)
            if var in (SA_CONTAINS, SA_STARTSWITH, SA_ENDSWITH):
                return AccelResult(TAG_BOOL, 1, heap_ptr)
        if sb.nchars > sa.nchars:
            return self._search_miss(var, heap_ptr)
        text = hay[start:end]
        nlen = sb.nchars

        def find_from(left: int) -> int:
            for i in range(left, len(hay) - nlen + 1):
                if i < start:
                    continue
                if i + nlen > end:
                    break
                if hay[i:i + nlen] == needle:
                    return i
            return -1

        if var == SA_FIND:
            idx = find_from(start)
            return AccelResult(TAG_INT, idx & VAL_MASK if idx >= 0 else (1 << 128) - 1, heap_ptr) if idx < 0 else AccelResult(TAG_INT, idx, heap_ptr)
        if var == SA_RFIND:
            idx = -1
            for i in range(end - nlen, start - 1, -1):
                if hay[i:i + nlen] == needle:
                    idx = i
                    break
            if idx < 0:
                return AccelResult(TAG_INT, (1 << 128) - 1, heap_ptr)
            return AccelResult(TAG_INT, idx, heap_ptr)
        if var == SA_COUNT:
            count = 0
            i = start
            while i + nlen <= end:
                if hay[i:i + nlen] == needle:
                    count += 1
                    i += nlen if nlen else 1
                else:
                    i += 1
            return AccelResult(TAG_INT, count, heap_ptr)
        if var == SA_CONTAINS:
            hit = find_from(start) >= 0
            return AccelResult(TAG_BOOL, int(hit), heap_ptr)
        if var == SA_STARTSWITH:
            hit = hay[start:start + nlen] == needle if start + nlen <= end else False
            return AccelResult(TAG_BOOL, int(hit), heap_ptr)
        if var == SA_ENDSWITH:
            hit = end >= nlen and hay[end - nlen:end] == needle
            return AccelResult(TAG_BOOL, int(hit), heap_ptr)
        return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)

    def _search_miss(self, var: int, heap_ptr: int) -> AccelResult:
        if var in (SA_FIND, SA_RFIND):
            return AccelResult(TAG_INT, (1 << 128) - 1, heap_ptr)
        if var == SA_COUNT:
            return AccelResult(TAG_INT, 0, heap_ptr)
        return AccelResult(TAG_BOOL, 0, heap_ptr)

    def _hash(self, a, heap_ptr: int) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        return AccelResult(TAG_INT, sa.digest, heap_ptr)

    def _char_at(
        self, a, b, heap_ptr: int, iter_next: bool = False
    ) -> AccelResult:
        sa = self._need_str(a, heap_ptr)
        if isinstance(sa, AccelResult):
            return sa
        idx = _int_val(*b)
        if idx is None:
            return AccelResult(0, 0, heap_ptr, True, TRAP_TYPE)
        if idx < 0:
            idx = sa.nchars + idx
        if idx < 0 or idx >= sa.nchars:
            if iter_next:
                return AccelResult(TAG_CONTROL, CTL_NONE, heap_ptr)
            return AccelResult(0, 0, heap_ptr, True, TRAP_MEM_FAULT)
        unit = sa.units(self.mem)[idx]
        # A 1-char result uses the kind of that code point (CPython compact).
        return pack_result_from_units(
            [unit], kind_of_unit(unit), self.mem, heap_ptr, self.heap_limit
        )

    def read_str(self, entry: tuple[int, int]) -> str:
        return decode_str(entry[0], entry[1], self.mem).text(self.mem)

    def put(self, text: str, heap_ptr: int, interned: bool = False) -> tuple[tuple[int, int], int]:
        """Allocate ``text`` and return ((tag, value), new_heap_ptr)."""
        r = self.alloc_str(text, heap_ptr, interned=interned)
        if r.trap:
            raise RuntimeError(f"alloc_str trap {r.trap_code}")
        return r.entry, r.heap_ptr
