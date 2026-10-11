#!/usr/bin/env python3
"""Host oracle for the PyCore garbage collector (planning/gc_plan.md §4.1, §10.2).

Given a dmem image (a `$readmemh` hex or a collector dump) and a root set,
`trace()` computes the live extents with the traversal rules of §4.1 and the
engine's deterministic order (every root, then every memory-root range, then
depth-first: pop the newest entry, discover its children in slot order). The
order matters for the mark-stack high-water mark, which G3 compares, and,
with a bounded stack, for which ranges go to the rescan list.

Like the engine, one pop scans at most GC_SCAN_CHUNK slots of a range and
pushes the rest first as a continuation entry. With `stack_limit` set, a
child that does not fit is left unmarked and the range being scanned is
recorded (once) in the rescan list, which is moved back onto the stack when
the stack drains; a root that does not fit is marked and recorded itself.
Marking is abandoned (`overflow`) only when the rescan list is full.

`check_dump()` verifies one collector dump (G3 unit runs and G4 system runs):
the free-run list against the complement of the reachable granules, the
engine counters, run-list well-formedness, and that the root stash written by
the RTL equals the root set the testbench recorded independently.

Dump format (written by pycore/tb/tb_gc.sv and pycore/tb/tb_container.sv):

    # pycore-gc-dump v1
    meta <key> <value>          decimal or 0x-hex
    root <tag> <value-hex>      testbench-recorded register/RF roots, in order
    mem <addr-hex> <word-hex>   non-zero 16 B words

Generational dumps (generational GC plan §4) add `meta gen 1`, `meta minor`,
`meta old_hi`, `meta force_major`, `meta remset_n`, `meta barrier_idle`, and:

    remset <kind> <size> <addr-hex>   one SSB entry: K_* kind, slot count, owner
    oldbm <word> <bits-hex>           pre-collection mark bitmap, nonzero words;
                                      bit b of word w is granule 128*w + b
    event <name> [<lo-hex> <hi-hex>]  what happened since the previous dump:
                                      release (of [lo, hi)), abandon, enable, reset

A minor is checked against `trace_minor` (exact under the plan's precision
contract (b)) and against the full trace (safety, barrier completeness); a
major exactly as before. `check_sequence()` checks a dump sequence: each
dump's old bitmap must follow from the previous collection and the events
between them.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from encoding import (  # noqa: E402
    BOOT_RECORD_ADDR,
    CODE_OBJECT_BYTES,
    EXC_STACK_BASE,
    FRAME_STACK_BASE,
    GC_COMPILER_CLEANUP,
    GC_EXTRA_ROOTS,
    GC_EXTRA_ROOTS_COUNT,
    GC_COMPILER_CLEANUP_MAGIC,
    GC_FREE_MAGIC,
    GC_MARK_STACK_ENTRIES,
    GC_RESCAN_ENTRIES,
    GC_ROOT_STASH,
    GC_RUN_TABLE,
    GC_RUN_TABLE_BYTES,
    GC_SCAN_CHUNK,
    GC_STATIC_MAP,
    GC_STATIC_MAP_BYTES,
    HEAP_BASE,
    HEAP_LIMIT,
    ITER_EXHAUST_TYPE_ADDR,
    MEMORY_ERROR_INSTANCE_ADDR,
    NATIVE_METHOD_COUNT,
    NATIVE_METHOD_TABLE_ADDR,
    RF_SPILL_BASE,
)

TAG_CONTROL, TAG_INT, TAG_FLOAT, TAG_COMPLEX, TAG_BOOL, TAG_ITER, TAG_TUPLE = range(7)
TAG_SHORT_STR, TAG_LONG_STR, TAG_MUT, TAG_OBJECT, TAG_RANGE, TAG_BYTES = range(7, 13)
TAG_CODE, TAG_TOMBSTONE, TAG_FROZENSET = 13, 14, 15
PTR_TAGS = {TAG_ITER, TAG_TUPLE, TAG_LONG_STR, TAG_MUT, TAG_OBJECT, TAG_RANGE, TAG_CODE}
RESERVED_TAGS = {TAG_BYTES, TAG_FROZENSET}

MUT_LIST, MUT_DICT, MUT_SET, MUT_BYTEARRAY = 1, 2, 3, 4
ITER_MAGIC = 0xA5
ITER_LIST, ITER_TUPLE, ITER_RANGE, ITER_STR, ITER_HEAP, ITER_DICT, ITER_SET = range(7)
OBK_EXTENT = {1: 64, 2: 128, 3: 96, 4: 96, 5: 128, 6: 96, 7: 64, 8: 96}
OBK_BYTEARRAY = 5
CTL_UNINIT = 0

# K_DICTT is only ever a continuation: dict table slots (64 B each).
K_TUPLE, K_CODE, K_LIST, K_DICT, K_SET, K_OBJ, K_STR, K_DICTT = range(8)
KIND_NAMES = ["TUPLE", "CODE", "LIST", "DICT", "SET", "OBJ", "STR", "DICTT"]
M64 = (1 << 64) - 1
M32 = (1 << 32) - 1


def pad16(n: int) -> int:
    return (n + 15) & ~15


def is_stracc_method_code(addr: int) -> bool:
    return (addr >> 8) & 0xFFFFFF == 0xFFFF00


class Memory:
    """Sparse 16 B-word memory; absent words read as zero."""

    def __init__(self, words: dict[int, int] | None = None) -> None:
        self.words = words or {}

    def rd(self, addr: int) -> int:
        return self.words.get(addr & ~15, 0)

    @classmethod
    def from_hex(cls, path: pathlib.Path) -> "Memory":
        words: dict[int, int] = {}
        addr = 0
        for line in pathlib.Path(path).read_text(encoding="ascii").split():
            if line.startswith("@"):
                addr = int(line[1:], 16) * 16
                continue
            w = int(line, 16)
            if w:
                words[addr] = w
            addr += 16
        return cls(words)


@dataclass
class TraceResult:
    marked: bytearray
    extents: list[tuple[int, int, str]] = field(default_factory=list)
    objects: int = 0
    roots: int = 0
    stack_hw: int = 0
    rescans: int = 0
    overflow: bool = False
    bad_kind: int = 0
    reserved: int = 0
    wild: int = 0
    kinds_seen: set[str] = field(default_factory=set)

    def live_granules(self, lo: int, hi: int) -> set[int]:
        return {g for g in range(lo >> 4, hi >> 4) if self.marked[g]}


class _Overflow(Exception):
    """The rescan list is full: the engine abandons the collection."""


def trace(
    mem: Memory,
    reg_roots: list[tuple[int, int]],
    *,
    spill_sp: int = RF_SPILL_BASE,
    exc_sp: int = EXC_STACK_BASE,
    frame_depth: int = 0,
    stack_limit: int | None = None,
    onchip: int = 256,
    rescan_limit: int | None = None,
    mutant: int = 0,
    pruned: set[int] | None = None,
    extra_roots: bool = True,
    remset: list[tuple[int, int, int]] | None = None,
    edges: list[tuple[int, int]] | None = None,
) -> TraceResult:
    """Mark everything reachable from the register roots and memory roots.

    `pruned` granules start marked, as the engine's static-map preload does.
    `stack_limit` (memory entries, beside `onchip`) bounds the mark stack;
    None is unbounded. `rescan_limit` bounds the rescan list.

    `remset` entries (kind, addr, size) are pushed after the memory roots
    without the mark test, as the generational engine's P_REMSET does
    (see trace_minor). With `edges` given, every reference found while
    scanning an object is appended as (owner, child): the owner is the
    object whose storage holds the slot (a list for its buffer's slots),
    the child the address pushed or raw-marked. Root references are not
    edges.
    """
    res = TraceResult(marked=bytearray(HEAP_LIMIT >> 4))
    marked = res.marked
    for g in pruned or ():
        marked[g] = 1
    # The object whose storage is being scanned (None for roots), and the
    # owner of each continuation or rescan entry that is not a whole object.
    owner: int | None = None
    chunk_owner: dict[tuple[int, int, int], int] = {}
    stack: list[tuple[int, int, int]] = []     # (kind, addr, size)
    rescan: list[tuple[int, int, int]] = []
    stack_cap = None if stack_limit is None else onchip + stack_limit
    # The range being scanned (None while tracing roots), and whether a child
    # of it has already been recorded.
    cur: tuple[int, int, int] | None = None
    recorded = False

    def valid(addr: int, length: int) -> bool:
        ok = (addr & 15) == 0 and HEAP_BASE <= addr < HEAP_LIMIT and length <= HEAP_LIMIT - addr
        if not ok:
            res.wild += 1
        return ok

    def mark_range(addr: int, length: int, what: str) -> None:
        for g in range(addr >> 4, ((addr + length - 1) >> 4) + 1):
            marked[g] = 1
        res.extents.append((addr, length, what))

    def edge(addr: int) -> None:
        if edges is not None and owner is not None:
            edges.append((owner, addr))

    def raw(addr: int, length: int, what: str) -> None:
        if length:
            edge(addr)
        if length and valid(addr, length):
            mark_range(addr, length, what)

    def test_set(addr: int, length: int, what: str) -> bool:
        if not valid(addr, length):
            return False
        if marked[addr >> 4]:
            return False
        mark_range(addr, length, what)
        return True

    def room() -> bool:
        return stack_cap is None or len(stack) < stack_cap

    def record(ent: tuple[int, int, int]) -> None:
        if rescan_limit is not None and len(rescan) >= rescan_limit:
            res.overflow = True
            raise _Overflow
        rescan.append(ent)
        res.rescans += 1
        if owner is not None:
            chunk_owner.setdefault(ent, owner)

    def stack_push(ent: tuple[int, int, int]) -> None:
        stack.append(ent)
        res.stack_hw = max(res.stack_hw, len(stack))

    def push(kind: int, addr: int, size: int, length: int, what: str) -> None:
        nonlocal recorded
        edge(addr)
        if not valid(addr, length) or marked[addr >> 4]:
            return
        if room():
            mark_range(addr, length, what)
            stack_push((kind, addr, size))
        elif cur is not None:
            # Leave the child unmarked; the whole range is scanned again.
            if not recorded:
                recorded = True
                record(cur)
        else:
            mark_range(addr, length, what)
            record((kind, addr, size))

    def scan_range(kind: int, base: int, count: int) -> None:
        """Scan one chunk of a 32 B (K_TUPLE) or dict-table (K_DICTT) range;
        the rest is pushed first, unmarked, as a continuation."""
        nonlocal cur, recorded
        stride = 64 if kind == K_DICTT else 32
        if count > GC_SCAN_CHUNK:
            rest = (kind, base + stride * GC_SCAN_CHUNK, count - GC_SCAN_CHUNK)
            if owner is not None:
                chunk_owner[rest] = owner
            if room():
                stack_push(rest)
            else:
                record(rest)
            count = GC_SCAN_CHUNK
        cur, recorded = (kind, base, count), False
        if kind == K_DICTT:
            scan_dict_table(base, count)
        else:
            scan_plain(base, count)

    def discover(tag: int, val: int) -> None:
        a32 = val & M32
        if tag == TAG_LONG_STR:
            n = 16 + pad16((val >> 96) & 0xFFFFFF)
            if mutant == 12:
                n -= 16
            edge(a32)
            if n and valid(a32, n) and not marked[a32 >> 4]:
                mark_range(a32, n, "LONG_STR")
            res.kinds_seen.add("LONG_STR")
        elif tag == TAG_TUPLE:
            size = val >> 64
            if size:
                if size >> 32:
                    res.wild += 1
                    return
                push(K_TUPLE, a32, size, size * 32, "TUPLE")
                res.kinds_seen.add("TUPLE")
        elif tag == TAG_MUT:
            mk = (val >> 124) & 0xF
            if mk == MUT_LIST:
                push(K_LIST, a32, 0, 32, "LIST")
            elif mk == MUT_DICT:
                push(K_DICT, a32, 0, 48, "DICT")
            elif mk == MUT_SET:
                push(K_SET, a32, 0, 32, "SET")
            elif mk == MUT_BYTEARRAY:
                push(K_OBJ, a32, 0, 16, "BYTEARRAY")
            else:
                res.bad_kind += 1
        elif tag == TAG_OBJECT:
            push(K_OBJ, a32, 0, 16, "OBJECT")
        elif tag == TAG_CODE:
            if not is_stracc_method_code(a32):
                push(K_CODE, a32, 0, CODE_OBJECT_BYTES, "CODE")
                res.kinds_seen.add("CODE")
        elif tag == TAG_RANGE:
            if (val >> 127) & 1 and mutant != 22:
                push(K_TUPLE, a32, 3, 96, "RANGE")
                res.kinds_seen.add("RANGE1")
        elif tag == TAG_ITER:
            if (val >> 120) & 0xFF != ITER_MAGIC:
                res.bad_kind += 1
                return
            ik = (val >> 116) & 0xF
            res.kinds_seen.add(f"ITER{ik}")
            if ik == ITER_LIST:
                push(K_LIST, a32, 0, 32, "LIST")
            elif ik == ITER_TUPLE:
                size = (val >> 32) & M32
                if size:
                    push(K_TUPLE, a32, size, size * 32, "TUPLE")
            elif ik == ITER_RANGE:
                pass
            elif ik == ITER_STR:
                if a32 == 0:
                    pass
                elif (val >> 96) & 1:
                    edge(a32)
                    if mutant != 21 and valid(a32, 16) and not marked[a32 >> 4]:
                        mark_range(a32, 16, "STR_SPILL")
                else:
                    push(K_STR, a32, 0, 16, "STR_HDR")
            elif ik == ITER_HEAP:
                push(K_OBJ, a32, 0, 16, "OBJECT")
            elif ik == ITER_DICT:
                push(K_DICT, a32, 0, 48, "DICT")
            elif ik == ITER_SET:
                push(K_SET, a32, 0, 32, "SET")
            else:
                res.bad_kind += 1
        elif tag in RESERVED_TAGS:
            res.reserved += 1

    def in_heap(base: int, nbytes: int) -> bool:
        # A header decoded from freed memory (after an unsafe collection)
        # can claim billions of slots; such a heap already fails, so only
        # bound the work.
        ok = nbytes == 0 or (HEAP_BASE <= base and base + nbytes <= HEAP_LIMIT)
        if not ok:
            res.wild += 1
        return ok

    def scan_plain(base: int, count: int) -> None:
        for i in range(count):
            tag = mem.rd(base + 32 * i + 16) & 0xF
            if tag in RESERVED_TAGS:
                res.reserved += 1
            if tag in PTR_TAGS:
                discover(tag, mem.rd(base + 32 * i))

    def slot_empty(tag_word: int) -> bool:
        return tag_word == 0 or ((tag_word & 0xF) == TAG_CONTROL and ((tag_word >> 4) & 0xF) == CTL_UNINIT)

    def scan_dict_table(base: int, slots: int) -> None:
        for i in range(slots):
            s = base + 64 * i
            ktw = mem.rd(s + 16)
            ktag = ktw & 0xF
            if slot_empty(ktw):
                continue
            if ktag == TAG_TOMBSTONE and mutant != 16:
                continue
            if mutant == 17 and ktag == TAG_CONTROL:
                continue
            if ktag in RESERVED_TAGS:
                res.reserved += 1
            if ktag in PTR_TAGS:
                discover(ktag, mem.rd(s))
            vtag = mem.rd(s + 48) & 0xF
            if vtag in RESERVED_TAGS:
                res.reserved += 1
            if vtag in PTR_TAGS:
                discover(vtag, mem.rd(s + 32))

    try:
        # ---- roots ----
        for tag, val in reg_roots:
            res.roots += 1
            discover(tag, val)
        if mutant != 9:
            scan_plain(BOOT_RECORD_ADDR, 3)
        if mutant != 10:
            scan_plain(NATIVE_METHOD_TABLE_ADDR, NATIVE_METHOD_COUNT)
        scan_plain(ITER_EXHAUST_TYPE_ADDR, 1)
        scan_plain(MEMORY_ERROR_INSTANCE_ADDR, 1)
        if extra_roots:
            scan_plain(GC_EXTRA_ROOTS, GC_EXTRA_ROOTS_COUNT)
        if mutant != 2:
            scan_plain(RF_SPILL_BASE, (spill_sp - RF_SPILL_BASE) >> 5)
        if mutant != 5:
            for node in range(EXC_STACK_BASE, exc_sp, 32):
                w = mem.rd(node + 16)
                if (w >> 127) & 1:
                    t = (w >> 120) & 0xF
                    if t in (TAG_OBJECT, TAG_CODE):
                        discover(t, w & M64)
                    elif t != TAG_CONTROL:
                        res.bad_kind += 1
        if mutant != 3:
            for k in range(frame_depth):
                w = mem.rd(FRAME_STACK_BASE + 32 * k + 16)
                if w & M32:
                    discover(TAG_CODE, w & M32)
                inst = (w >> 33) & M64
                if inst:
                    discover(TAG_OBJECT, inst)
                glob = (w >> 97) & ((1 << 31) - 1)
                if glob and mutant != 4:
                    discover(TAG_MUT, (MUT_DICT << 124) | glob)

        # ---- remembered set (generational minor) ----
        # Each owner is pushed as an already-marked entry: no mark test, and
        # the root rule when the stack is full (record it for a rescan).
        for ent in remset or ():
            if room():
                stack_push(ent)
            else:
                record(ent)

        # ---- depth-first marking ----
        while stack or rescan:
            if not stack:
                stack_push(rescan.pop())
            kind, addr, size = stack.pop()
            owner = chunk_owner.get((kind, addr, size), addr)
            res.objects += 1
            res.kinds_seen.add(KIND_NAMES[kind])
            cur, recorded = (kind, addr, size), False
            if kind == K_TUPLE:
                scan_range(K_TUPLE, addr, size)
            elif kind == K_DICTT:
                scan_range(K_DICTT, addr, size)
            elif kind == K_CODE:
                if mutant == 20:
                    scan_plain(addr + 64, 6)
                else:
                    scan_plain(addr, 8)
            elif kind == K_LIST:
                hdr = mem.rd(addr)
                cap, length = (hdr >> 64) & M32, hdr & M32
                if (hdr & M64) > (hdr >> 64):
                    res.bad_kind += 1
                buf = mem.rd(addr + 16) & M32
                if cap and buf:
                    raw(buf, (length if mutant == 14 else cap) * 32, "LIST_BUF")
                n = length - 1 if (mutant == 13 and length) else length
                if in_heap(buf, n * 32):
                    scan_range(K_TUPLE, buf, n)
            elif kind == K_SET:
                slots = (mem.rd(addr) >> 64) & M32
                table = mem.rd(addr + 16) & M32
                if slots and table:
                    if mutant != 18:
                        raw(table, slots * 32, "SET_TABLE")
                    if in_heap(table, slots * 32):
                        scan_range(K_TUPLE, table, slots)
            elif kind == K_DICT:
                slots = (mem.rd(addr) >> 64) & M32
                order_len = mem.rd(addr + 16) & M32
                ptrs = mem.rd(addr + 32)
                order, table = (ptrs >> 64) & M32, ptrs & M32
                if slots and order and mutant != 15:
                    raw(order, slots * 32, "DICT_ORDER")
                if slots and table:
                    raw(table, slots * 64, "DICT_TABLE")
                if order and in_heap(order, order_len * 32):
                    scan_range(K_TUPLE, order, order_len)
                if slots and table and in_heap(table, slots * 64):
                    scan_range(K_DICTT, table, slots)
            elif kind == K_OBJ:
                head = mem.rd(addr)
                ob_kind = head >> 96
                ext = OBK_EXTENT.get(ob_kind, 0)
                if not ext:
                    res.bad_kind += 1
                    continue
                raw(addr, ext, f"OBK{ob_kind}")
                res.kinds_seen.add(f"OBK{ob_kind}")
                ob_type = head & M64
                if ob_type and mutant != 19:
                    discover(TAG_OBJECT, ob_type)
                if ob_kind == OBK_BYTEARRAY:
                    buf = mem.rd(addr + 64) & M32
                    cap = mem.rd(addr + 96) & M32
                    if buf and cap and mutant != 23:
                        raw(buf, pad16(cap), "BYTEARRAY_BUF")
                else:
                    scan_plain(addr + 32, (ext - 32) // 32)
            elif kind == K_STR:
                n = (mem.rd(addr) >> 96) & 0xFFFFFF
                raw(addr, 16 + pad16(n), "LONG_STR")
    except _Overflow:
        pass
    return res


def all_free_runs(res: TraceResult, dyn_base: int, heap_limit: int) -> list[tuple[int, int]]:
    runs = []
    start = None
    for g in range(dyn_base >> 4, heap_limit >> 4):
        if not res.marked[g]:
            if start is None:
                start = g
        elif start is not None:
            runs.append((start << 4, (g - start) << 4))
            start = None
    if start is not None:
        runs.append((start << 4, (heap_limit >> 4 << 4) - (start << 4)))
    return runs


def expected_runs(res: TraceResult, dyn_base: int, heap_limit: int) -> list[tuple[int, int]]:
    # The allocator requires size >= need+64, so a run shorter than 64 B is
    # never installed. The engine omits those pads from the list (G13 P4).
    return [(b, s) for b, s in all_free_runs(res, dyn_base, heap_limit) if s >= 64]


# --------------------------------------------------------------------------
# Dumps
# --------------------------------------------------------------------------

@dataclass
class Dump:
    meta: dict[str, int]
    roots: list[tuple[int, int]]
    mem: Memory
    path: str = ""
    remset: list[tuple[int, int, int]] = field(default_factory=list)   # (kind, addr, size)
    oldbm: dict[int, int] = field(default_factory=dict)                # word -> 128 bits
    events: list[tuple[str, int, int]] = field(default_factory=list)   # (name, lo, hi)

    @property
    def gen(self) -> bool:
        return bool(self.meta.get("gen", 0))

    @property
    def minor(self) -> bool:
        return self.gen and bool(self.meta.get("minor", 0))


def parse_int(s: str) -> int:
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def load_dump(path: pathlib.Path) -> Dump:
    meta: dict[str, int] = {}
    roots: list[tuple[int, int]] = []
    words: dict[int, int] = {}
    d = Dump(meta, roots, Memory(), str(path))
    d.mem.words = words
    for line in pathlib.Path(path).read_text(encoding="ascii").splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        if parts[0] == "meta":
            meta[parts[1]] = parse_int(parts[2])
        elif parts[0] == "root":
            roots.append((int(parts[1]), int(parts[2], 16)))
        elif parts[0] == "mem":
            w = int(parts[2], 16)
            if w:
                words[int(parts[1], 16)] = w
        elif parts[0] == "remset":
            d.remset.append((int(parts[1]), int(parts[3], 16), int(parts[2])))
        elif parts[0] == "oldbm":
            w = int(parts[2], 16)
            if w:
                d.oldbm[int(parts[1])] = w
        elif parts[0] == "event":
            lo, hi = (int(parts[2], 16), int(parts[3], 16)) if len(parts) >= 4 else (0, 0)
            d.events.append((parts[1], lo, hi))
    return d


def bitmap_granules(bm: dict[int, int]) -> bytearray:
    """A 128-bit-word bitmap as one byte per granule."""
    out = bytearray(HEAP_LIMIT >> 4)
    for w, bits in bm.items():
        while bits:
            b = bits & -bits
            g = (w << 7) + b.bit_length() - 1
            if g < len(out):
                out[g] = 1
            bits ^= b
    return out


def granules_bitmap(marked: bytearray) -> dict[int, int]:
    """The inverse of bitmap_granules: nonzero 128-bit words."""
    out: dict[int, int] = {}
    g = marked.find(1)
    while g >= 0:
        out[g >> 7] = out.get(g >> 7, 0) | (1 << (g & 127))
        g = marked.find(1, g + 1)
    return out


def trace_minor(mem: Memory, reg_roots: list[tuple[int, int]], old: bytearray,
                remset: list[tuple[int, int, int]], **kw) -> TraceResult:
    """A sticky-mark-bit minor: `old` granules start marked (the bitmap the
    previous collection left, static granules included), remembered owners
    are scanned unconditionally after the roots, and the rest is `trace`."""
    return trace(mem, reg_roots, pruned=set(_ones(old)), remset=remset, **kw)


def _ones(marked: bytearray):
    g = marked.find(1)
    while g >= 0:
        yield g
        g = marked.find(1, g + 1)


def barrier_gaps(edges: list[tuple[int, int]], reachable: bytearray, old: bytearray,
                 remset: list[tuple[int, int, int]], dyn_base: int) -> list[tuple[int, int]]:
    """Edges from an old owner to a reachable young object or buffer whose
    owner is not in the remembered set (plan §4, rule 3). Only dynamic
    storage is young: below dyn_base nothing is ever freed, so an unmarked
    static granule after a major is not a barrier obligation."""
    logged = {a for _, a, _ in remset}
    out = []
    for o, c in edges:
        if (old[o >> 4] and o not in logged and dyn_base <= c < HEAP_LIMIT and reachable[c >> 4]
                and not old[c >> 4]):
            out.append((o, c))
    return out


def pruned_granules(words: dict[int, int]) -> set[int]:
    """Granules whose map bit is set, from a memory image or dump.

    Only the GC_STATIC_MAP_BYTES region is a map: the engine reads no
    further (the run table follows it)."""
    out = set()
    for w in range(min(HEAP_LIMIT >> 11, GC_STATIC_MAP_BYTES // 16)):
        bits = words.get(GC_STATIC_MAP + 16 * w, 0)
        while bits:
            b = bits & -bits
            out.add((w << 7) + b.bit_length() - 1)
            bits ^= b
    return out


def compiler_idle_premark(mem: Memory, dyn_base: int) -> set[int]:
    """Static dictionary headers manually premarked by the RTL cleanup pass."""
    header = mem.rd(GC_COMPILER_CLEANUP)
    count = (header >> 64) & M32
    busy_addr = (header >> 32) & M32
    pyc_g = (header & 0xFFFF) << 4
    builtins = ((header >> 16) & 0xFFFF) << 4
    if ((header >> 96) != GC_COMPILER_CLEANUP_MAGIC or
            not 0 < count <= 188 or
            not HEAP_BASE <= busy_addr or busy_addr + 16 >= dyn_base or
            not HEAP_BASE <= pyc_g < dyn_base or
            not (builtins == 0 or HEAP_BASE <= builtins < dyn_base) or
            mem.rd(busy_addr) != 0):
        return set()
    # Builtins is premarked only when the image listed its kept values as
    # extra roots (field 0 otherwise).
    return {pyc_g >> 4} | ({builtins >> 4} if builtins else set())


def stash_roots(mem: Memory) -> list[tuple[int, int]]:
    n = mem.rd(GC_ROOT_STASH) & M32
    return [(mem.rd(GC_ROOT_STASH + 32 + 32 * i) & 0xF, mem.rd(GC_ROOT_STASH + 16 + 32 * i))
            for i in range(n)]


def walk_runs(mem: Memory, head: int, dyn_base: int, heap_limit: int,
              problems: list[str]) -> list[tuple[int, int]]:
    runs = []
    addr = head
    limit = (heap_limit - dyn_base) // 16 + 2
    while addr:
        if len(runs) > limit:
            problems.append("run list does not terminate")
            break
        w = mem.rd(addr)
        magic, size, nxt, base = w >> 96, (w >> 64) & M32, (w >> 32) & M32, w & M32
        run = base if base else addr
        in_table = GC_RUN_TABLE <= addr < GC_RUN_TABLE + GC_RUN_TABLE_BYTES
        if magic != GC_FREE_MAGIC:
            problems.append(f"run at {addr:#x}: bad magic {magic:#x}")
            break
        if size == 0 or size & 15 or addr & 15 or run & 15:
            problems.append(f"run at {addr:#x}: bad size/alignment {size}")
        if run < dyn_base or run + size > heap_limit:
            problems.append(f"run at {run:#x}+{size} outside [{dyn_base:#x},{heap_limit:#x})")
        elif not in_table and (addr < dyn_base or addr + size > heap_limit):
            problems.append(f"run header at {addr:#x}+{size} outside heap")
        if runs and run <= runs[-1][0] + runs[-1][1]:
            prev = runs[-1]
            kind = "overlaps" if run < prev[0] + prev[1] else "is adjacent to (not maximal)"
            problems.append(f"run at {run:#x} {kind} run at {prev[0]:#x}+{prev[1]}")
        runs.append((run, size))
        addr = nxt
    return runs


def check_dump(dump: Dump, *, compare_hw: bool = False, mutant: int = 0) -> list[str]:
    """Return a list of discrepancies (empty = the collection was exact)."""
    return _check(dump, compare_hw=compare_hw, mutant=mutant).problems


@dataclass
class Outcome:
    """What _check learned about one collection. `post` is the oracle's
    bitmap after it (None when marking was abandoned), `freed` the granules
    the RTL's run list frees, `reach` the full trace's reachable set."""
    problems: list[str]
    post: bytearray | None = None
    freed: bytearray | None = None
    reach: bytearray | None = None


def _check(dump: Dump, *, compare_hw: bool = False, mutant: int = 0) -> Outcome:
    m = dump.meta
    problems: list[str] = []
    dyn_base, heap_limit = m["dyn_base"], m["heap_limit"]
    # An overflowed collection aborts before the stash count and run list
    # are written; only the overflow itself is checked.
    # Independent roots: the RTL's stash must equal the TB's record.
    if m.get("stash_en", 0) and not m.get("overflow", 0):
        stash = stash_roots(dump.mem)
        if stash != dump.roots:
            n = min(len(stash), len(dump.roots))
            first = next((i for i in range(n) if stash[i] != dump.roots[i]), n)
            problems.append(
                f"root stash ({len(stash)} roots) differs from testbench roots "
                f"({len(dump.roots)}) at index {first}")
    # The RTL traces with the static prune map preloaded and its own stack and
    # rescan-list limits; its counters and overflow follow that trace. The
    # free set is always judged against the unpruned, unbounded trace, so an
    # unsound map is a SAFETY failure here. Dumps without the limits predate
    # them and ran with the defaults.
    kw = dict(spill_sp=m.get("spill_sp", RF_SPILL_BASE),
              exc_sp=m.get("exc_sp", EXC_STACK_BASE), frame_depth=m.get("frame_depth", 0),
              mutant=mutant, extra_roots=bool(m.get("extra_roots", 1)))
    limits = dict(stack_limit=m.get("stack_limit", GC_MARK_STACK_ENTRIES),
                  onchip=m.get("onchip", 256),
                  rescan_limit=m.get("rescan_limit", GC_RESCAN_ENTRIES))
    old = bitmap_granules(dump.oldbm) if dump.gen else None
    if dump.gen:
        problems += gen_invariants(dump, old)
    if dump.minor:
        # A minor neither clears nor preloads: the old bitmap is the start.
        pruned = set()
        res_p = trace_minor(dump.mem, dump.roots, old, dump.remset, **kw, **limits)
    else:
        pruned = {g for g in pruned_granules(dump.mem.words) if g < dyn_base >> 4}
        pruned |= compiler_idle_premark(dump.mem, dyn_base)
        res_p = trace(dump.mem, dump.roots, pruned=pruned, **kw, **limits)
    if m.get("overflow", 0) or res_p.overflow:
        if not res_p.overflow:
            problems.append("RTL abandoned marking (rescan list full) but the oracle's fits")
        elif not m.get("overflow", 0):
            problems.append("oracle's rescan list overflows but the RTL finished marking")
        return Outcome(problems)
    # Bounded marking that rescanned reaches the same set; reuse it only when
    # it is the same trace.
    edges: list[tuple[int, int]] = []
    if dump.minor:
        res = trace(dump.mem, dump.roots, edges=edges, **kw)
    else:
        res = res_p if not pruned and not res_p.rescans else trace(dump.mem, dump.roots, **kw)
    for k in ("bad_kind", "reserved", "wild"):
        if getattr(res, k):
            problems.append(f"oracle saw {k}={getattr(res, k)} (heap or roots malformed)")
        if m.get(k, 0):
            problems.append(f"RTL reported {k}={m[k]}")
    if pruned:
        hidden = [g for g in range(dyn_base >> 4, heap_limit >> 4)
                  if res.marked[g] and not res_p.marked[g]]
        if hidden:
            problems.append(f"SAFETY: static prune map hides {len(hidden)} reachable dynamic "
                            f"granules, first at {hidden[0] << 4:#x} "
                            f"({describe(res, hidden[0] << 4)})")
    if dump.minor:
        # Contract (b): a minor frees exactly the unreachable young storage,
        # so its runs are judged against trace_minor. Safety and the barrier
        # are judged against the full trace.
        missed = [g for g in range(dyn_base >> 4, heap_limit >> 4)
                  if res.marked[g] and not res_p.marked[g]]
        if missed:
            problems.append(f"SAFETY: the minor trace misses {len(missed)} reachable granules, "
                            f"first at {missed[0] << 4:#x} ({describe(res, missed[0] << 4)})")
        gaps = barrier_gaps(edges, res.marked, old, dump.remset, dyn_base)
        if gaps:
            o, c = gaps[0]
            problems.append(f"BARRIER: {len(gaps)} old-to-young references from owners not in the "
                            f"remembered set, first {o:#x} ({describe(res, o)}) -> {c:#x} "
                            f"({describe(res, c)})")
    basis = res_p if dump.minor else res
    want_all = all_free_runs(basis, dyn_base, heap_limit)
    # A collection with no allocation to satisfy keeps the current run
    # [keep_lo, keep_hi): it holds no object, it is free, and the engine
    # lists the free memory around it as separate runs.
    klo, khi = m.get("keep_lo", 0), m.get("keep_hi", 0)
    keep = (klo, khi - klo) if khi > klo else None
    if keep:
        if not any(b <= klo and khi <= b + s for b, s in want_all):
            problems.append(f"SAFETY: kept run [{klo:#x}, {khi:#x}) is not free")
        split: list[tuple[int, int]] = []
        for b, s in want_all:
            e = b + s
            if e <= klo or b >= khi:
                split.append((b, s))
                continue
            if b < klo:
                split.append((b, klo - b))
            if e > khi:
                split.append((khi, e - khi))
        want_all = split
    want = [(b, s) for b, s in want_all if s >= 64]
    got = walk_runs(dump.mem, m["run_head"], dyn_base, heap_limit, problems)
    freed = bytearray(HEAP_LIMIT >> 4)
    for b, sz in got:
        lo, hi = b >> 4, min((b + sz) >> 4, len(freed))
        if hi > lo:
            freed[lo:hi] = b"\x01" * (hi - lo)
    if dump.minor:
        got_g = [g for b, s in got for g in range(b >> 4, (b + s) >> 4)]
        live = [g for g in got_g if res.marked[g]]
        if live:
            problems.append(f"SAFETY: minor freed {len(live)} reachable granules, first at "
                            f"{live[0] << 4:#x} ({describe(res, live[0] << 4)})")
        freed_old = [g for g in got_g if old[g]]
        if freed_old:
            problems.append(f"SAFETY: minor freed {len(freed_old)} old granules, first at "
                            f"{freed_old[0] << 4:#x}")
    if got != want:
        want_free = {g for b, s in want for g in range(b >> 4, (b + s) >> 4)}
        got_free = {g for b, s in got for g in range(b >> 4, (b + s) >> 4)}
        unsafe = sorted(got_free - want_free)
        leak = sorted(want_free - got_free)
        if unsafe:
            problems.append(f"SAFETY: {len(unsafe)} reachable granules freed, first at "
                            f"{unsafe[0] << 4:#x} ({describe(basis, unsafe[0] << 4)})")
        if leak:
            problems.append(f"PRECISION: {len(leak)} unreachable granules retained, first at "
                            f"{leak[0] << 4:#x}")
        if not unsafe and not leak:
            problems.append("run boundaries differ from the oracle's maximal runs")
    cands = ([keep] if keep else []) + want_all
    # Next-fit start: the engine counts the listed on-chip runs (the first
    # 1024, address order) whose base is below rover_addr.
    if "rover" in m:
        want_rover = sum(1 for b, _ in want[:1024] if b < m.get("rover_addr", 0))
        if m["rover"] != want_rover:
            problems.append(f"counter rover: RTL {m['rover']} oracle {want_rover}")
    free = sum(s for _, s in cands)
    largest = max((s for _, s in cands), default=0)
    largest_base = next((b for b, s in cands if s == largest), 0) if largest else 0
    checks = {
        "free": free,
        "live": (heap_limit - dyn_base) - free,
        "largest": largest,
        "largest_base": largest_base,
        "runs": len(want),
        "roots": res_p.roots,
        "objects": res_p.objects,
        "rescans": res_p.rescans,
    }
    if compare_hw:
        checks["stack_hw"] = res_p.stack_hw
    for k, v in checks.items():
        if k in m and m[k] != v:
            problems.append(f"counter {k}: RTL {m[k]} oracle {v}")
    if "free_before" in m and "reclaimed" in m:
        if m["reclaimed"] != free - m["free_before"]:
            problems.append(f"counter reclaimed: RTL {m['reclaimed']} expected "
                            f"{free - m['free_before']} (free {free} - free_before {m['free_before']})")
    return Outcome(problems, res_p.marked, freed, res.marked)


def gen_invariants(dump: Dump, old: bytearray) -> list[str]:
    """Entry-state invariants of a generational dump (plan §3.7)."""
    m = dump.meta
    out = []
    if m.get("barrier_idle", 1) != 1:
        out.append("collection entered with barrier requests in flight (barrier_idle=0)")
    if dump.minor and m.get("force_major", 0):
        out.append("a minor ran with force_major set")
    if "remset_n" in m and m["remset_n"] != len(dump.remset):
        out.append(f"remset_n {m['remset_n']} but {len(dump.remset)} remset lines")
    if dump.minor:
        young = [(k, a) for k, a, _ in dump.remset if not old[a >> 4]]
        if young:
            out.append(f"{len(young)} remset entries name a non-old owner, first "
                       f"{KIND_NAMES[young[0][0]] if young[0][0] < len(KIND_NAMES) else young[0][0]} "
                       f"at {young[0][1]:#x}")
    klo, khi = m.get("keep_lo", 0), m.get("keep_hi", 0)
    set_in_keep = [g for g in range(klo >> 4, khi >> 4) if old[g]] if khi > klo else []
    if set_in_keep:
        out.append(f"kept run [{klo:#x}, {khi:#x}) holds {len(set_in_keep)} set bits, first at "
                   f"{set_in_keep[0] << 4:#x}")
    if "old_hi" in m:
        above = old.find(1, m["old_hi"] >> 4)
        if above >= 0:
            out.append(f"old bit at {above << 4:#x} at or above old_hi {m['old_hi']:#x}")
    return out


# Granule state table (pycore/docs/gc_gen_protocol.md §1), for dynamic
# granules, as the RTL shows them: the bit at entry (oldbm), whether the full
# trace reaches the granule, what the collection did with it (`free`: in the
# run list; `kept`: the kept bump run; `held`: neither, so an object or a
# pad shorter than 64 B), and the bit at the next entry. A release between
# the two collections clears the bit (the `released` rows).
#   (entry bit, kind, reachable) -> allowed (exit, next bit)
STATE_TABLE: dict[tuple[int, str, bool], set[tuple[str, int]]] = {
    (1, "minor", True): {("held", 1)},
    (1, "minor", False): {("held", 1)},            # tenured garbage waits for a major
    (0, "minor", True): {("held", 1)},             # young survivor, promoted
    (0, "minor", False): {("free", 0), ("kept", 0), ("held", 0),
                          ("held", 1)},            # held+1: reached from a remembered owner
    (1, "major", True): {("held", 1)},
    (1, "major", False): {("free", 0), ("held", 0)},
    (0, "major", True): {("held", 1)},
    (0, "major", False): {("free", 0), ("kept", 0), ("held", 0)},
}
# Every (row, exit, next bit) any check_sequence call has seen; the unit
# tests require each legal one, released or not, to be exercised.
STATES_SEEN: set[tuple[int, str, bool, str, int, bool]] = set()


def table_rows() -> set[tuple[int, str, bool, str, int, bool]]:
    """Every legal transition: STATE_TABLE, plus each row with a release
    before the next entry, which leaves the bit clear whatever the exit."""
    out = set()
    for (e, k, r), exits in STATE_TABLE.items():
        for x, n in exits:
            out.add((e, k, r, x, n, False))
            out.add((e, k, r, x, 0, True))
    return out


def check_states(d: Dump, o: Outcome, nxt: bytearray | None, released: bytearray | None) -> list[str]:
    """Check every dynamic granule of collection `d` against STATE_TABLE.
    `nxt` is the next entry's bitmap (None: no next dump, or an event made
    it unconstrained); `released` marks granules released in between."""
    if o.post is None or o.freed is None or not d.gen:
        return []
    m = d.meta
    lo, hi = m["dyn_base"] >> 4, m["heap_limit"] >> 4
    entry = bitmap_granules(d.oldbm)
    klo, khi = m.get("keep_lo", 0) >> 4, m.get("keep_hi", 0) >> 4
    kind = "minor" if d.minor else "major"
    seen: dict[tuple, int] = {}
    for g in range(lo, hi):
        x = "free" if o.freed[g] else "kept" if klo <= g < khi else "held"
        rel = bool(released and released[g])
        key = (entry[g], kind, bool(o.reach[g]), x, nxt[g] if nxt is not None else -1, rel)
        if key not in seen:
            seen[key] = g
    out = []
    legal = table_rows()
    for key, g in seen.items():
        e, k, r, x, n, rel = key
        if n == -1:
            ok = any((x, nn) in STATE_TABLE[(e, k, r)] for nn in (0, 1))
        elif rel:
            ok = n == 0 and any(x == xx for xx, _ in STATE_TABLE[(e, k, r)])
        else:
            ok = (x, n) in STATE_TABLE[(e, k, r)]
        if n != -1:
            STATES_SEEN.add((e, k, r, x, n, rel) if (e, k, r, x, n, rel) in legal else key)
        if not ok:
            out.append(f"STATE: granule {g << 4:#x}: bit {e} at entry, {'reachable' if r else 'unreachable'}, "
                       f"{k} left it {x}" + (f", bit {n} at the next entry" if n != -1 else "")
                       + (" after a release" if rel else "") + " (not in the state table)")
    return out


def check_sequence(dumps: list[Dump], *, compare_hw: bool = False,
                   mutant: int = 0) -> list[tuple[Dump, list[str]]]:
    """check_dump for each dump, plus the sequence rules of plan §4: the old
    bitmap at each generational entry must be the bitmap the previous
    collection left (its marked set; trace_minor's marks include the old
    set), minus released ranges. After an abandoned collection, an enable or
    a reset the bitmap is unconstrained and the collection must be a major.
    Each collection's granules are also checked against STATE_TABLE."""
    outs = [_check(d, compare_hw=compare_hw, mutant=mutant) for d in dumps]
    out = []
    for i, d in enumerate(dumps):
        o = outs[i]
        problems = o.problems
        prev = dumps[i - 1] if i else None
        prev_post = outs[i - 1].post if i else None
        names = [e[0] for e in d.events]
        for name, lo, hi in d.events:
            if name not in ("release", "abandon", "enable", "reset"):
                problems.append(f"unknown event {name!r}")
            elif name == "release":
                inside = [a for _, a, _ in d.remset if lo <= a < hi]
                if inside:
                    problems.append(f"remset entry at {inside[0]:#x} inside released [{lo:#x}, {hi:#x})")
        if d.gen:
            fresh = (prev is None or not prev.gen or prev_post is None
                     or any(n in ("abandon", "enable", "reset") for n in names))
            if fresh:
                if d.minor and (prev is not None or names):
                    problems.append("SEQUENCE: a minor after an abandon, enable or reset "
                                    "(it must be a major)")
            else:
                want = bytearray(prev_post)
                for name, lo, hi in d.events:
                    if name == "release":
                        want[lo >> 4:hi >> 4] = bytes((hi >> 4) - (lo >> 4))
                got = bitmap_granules(d.oldbm)
                if got != want:
                    extra = next((g for g in _ones(got) if not want[g]), None)
                    lost = next((g for g in _ones(want) if not got[g]), None)
                    what = (f"set bit at {extra << 4:#x} the previous collection did not leave"
                            if extra is not None else f"bit at {lost << 4:#x} the previous "
                            f"collection left is clear")
                    problems.append(f"SEQUENCE: old bitmap differs from the previous "
                                    f"{'minor' if prev.minor else 'major'}'s result: {what}")
        # The state table, with this collection's exit read from the next
        # dump's entry bitmap when nothing between them unconstrains it.
        nxt = released = None
        if i + 1 < len(dumps):
            n = dumps[i + 1]
            if n.gen and not any(e[0] in ("abandon", "enable", "reset") for e in n.events):
                nxt = bitmap_granules(n.oldbm)
                rels = [(lo, hi) for name, lo, hi in n.events if name == "release"]
                if rels:
                    released = bytearray(HEAP_LIMIT >> 4)
                    for lo, hi in rels:
                        released[lo >> 4:hi >> 4] = b"\x01" * ((hi >> 4) - (lo >> 4))
        problems += check_states(d, o, nxt, released)
        out.append((d, problems))
    return out


def describe(res: TraceResult, addr: int) -> str:
    for a, n, what in res.extents:
        if a <= addr < a + n:
            return f"{what} at {a:#x}+{n}"
    return "?"


def dump_order(p: pathlib.Path) -> tuple[int, str]:
    """Collection order: the number in the name (gc10 after gc9)."""
    digits = "".join(c for c in p.stem if c.isdigit())
    return (int(digits) if digits else -1, p.name)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", nargs="*", default=[], help="dump files or directories")
    ap.add_argument("--hw", action="store_true", help="also compare the mark-stack high-water mark")
    ap.add_argument("--mutant", type=int, default=0)
    ap.add_argument("--max", type=int, default=0, help="check at most N dumps per directory")
    ap.add_argument("--sequence", action="store_true",
                    help="also apply the generational sequence rules across the dumps, in name order")
    args = ap.parse_args()
    paths: list[pathlib.Path] = []
    for p in map(pathlib.Path, args.check):
        if p.is_dir():
            found = sorted(p.glob("*.gcdump"), key=dump_order if args.sequence else (lambda x: x.name))
            paths += found[: args.max] if args.max else found
        else:
            paths.append(p)
    bad = 0
    if args.sequence:
        checked = [(pathlib.Path(d.path), pr) for d, pr in
                   check_sequence([load_dump(p) for p in paths], compare_hw=args.hw, mutant=args.mutant)]
    else:
        checked = ((p, check_dump(load_dump(p), compare_hw=args.hw, mutant=args.mutant)) for p in paths)
    for p, problems in checked:
        if problems:
            bad += 1
            print(f"FAIL {p}")
            for x in problems[:12]:
                print(f"  {x}")
        else:
            print(f"ok   {p}")
    print(f"gc_model: {len(paths) - bad}/{len(paths)} dumps exact")
    return 1 if bad or not paths else 0


if __name__ == "__main__":
    raise SystemExit(main())
