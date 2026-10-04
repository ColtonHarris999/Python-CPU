#!/usr/bin/env python3
"""Host oracle for the PyCore garbage collector (planning/gc_plan.md §4.1, §10.2).

Given a dmem image (a `$readmemh` hex or a collector dump) and a root set,
`trace()` computes the live extents with the traversal rules of §4.1 and the
engine's deterministic order (every root, then every memory-root range, then
depth-first: pop the newest entry, discover its children in slot order). The
order matters only for the mark-stack high-water mark, which G3 compares.

`check_dump()` verifies one collector dump (G3 unit runs and G4 system runs):
the free-run list against the complement of the reachable granules, the
engine counters, run-list well-formedness, and that the root stash written by
the RTL equals the root set the testbench recorded independently.

Dump format (written by pycore/tb/tb_gc.sv and pycore/tb/tb_container.sv):

    # pycore-gc-dump v1
    meta <key> <value>          decimal or 0x-hex
    root <tag> <value-hex>      testbench-recorded register/RF roots, in order
    mem <addr-hex> <word-hex>   non-zero 16 B words
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
    GC_ROOT_STASH,
    GC_RUN_TABLE,
    GC_RUN_TABLE_BYTES,
    GC_STATIC_MAP,
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

K_TUPLE, K_CODE, K_LIST, K_DICT, K_SET, K_OBJ, K_STR = range(7)
KIND_NAMES = ["TUPLE", "CODE", "LIST", "DICT", "SET", "OBJ", "STR"]
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
    overflow: bool = False
    bad_kind: int = 0
    reserved: int = 0
    wild: int = 0
    kinds_seen: set[str] = field(default_factory=set)

    def live_granules(self, lo: int, hi: int) -> set[int]:
        return {g for g in range(lo >> 4, hi >> 4) if self.marked[g]}


def trace(
    mem: Memory,
    reg_roots: list[tuple[int, int]],
    *,
    spill_sp: int = RF_SPILL_BASE,
    exc_sp: int = EXC_STACK_BASE,
    frame_depth: int = 0,
    stack_limit: int | None = None,
    onchip: int = 256,
    mutant: int = 0,
    pruned: set[int] | None = None,
    extra_roots: bool = True,
) -> TraceResult:
    """Mark everything reachable from the register roots and memory roots.

    `pruned` granules start marked, as the engine's static-map preload does.
    """
    res = TraceResult(marked=bytearray(HEAP_LIMIT >> 4))
    marked = res.marked
    for g in pruned or ():
        marked[g] = 1
    stack: list[tuple[int, int, int]] = []

    def valid(addr: int, length: int) -> bool:
        ok = (addr & 15) == 0 and HEAP_BASE <= addr < HEAP_LIMIT and length <= HEAP_LIMIT - addr
        if not ok:
            res.wild += 1
        return ok

    def mark_range(addr: int, length: int, what: str) -> None:
        for g in range(addr >> 4, ((addr + length - 1) >> 4) + 1):
            marked[g] = 1
        res.extents.append((addr, length, what))

    def raw(addr: int, length: int, what: str) -> None:
        if length and valid(addr, length):
            mark_range(addr, length, what)

    def test_set(addr: int, length: int, what: str) -> bool:
        if not valid(addr, length):
            return False
        if marked[addr >> 4]:
            return False
        mark_range(addr, length, what)
        return True

    def push(kind: int, addr: int, size: int, length: int, what: str) -> None:
        if test_set(addr, length, what):
            stack.append((kind, addr, size))
            res.stack_hw = max(res.stack_hw, len(stack))
            if stack_limit is not None and len(stack) > onchip + stack_limit:
                res.overflow = True

    def discover(tag: int, val: int) -> None:
        a32 = val & M32
        if tag == TAG_LONG_STR:
            n = 16 + pad16((val >> 96) & 0xFFFFFF)
            if mutant == 12:
                n -= 16
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

    # ---- depth-first marking ----
    while stack:
        kind, addr, size = stack.pop()
        res.objects += 1
        res.kinds_seen.add(KIND_NAMES[kind])
        if kind == K_TUPLE:
            scan_plain(addr, size)
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
                scan_plain(buf, n)
        elif kind == K_SET:
            slots = (mem.rd(addr) >> 64) & M32
            table = mem.rd(addr + 16) & M32
            if slots and table:
                if mutant != 18:
                    raw(table, slots * 32, "SET_TABLE")
                if in_heap(table, slots * 32):
                    scan_plain(table, slots)
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
                scan_plain(order, order_len)
            if slots and table and in_heap(table, slots * 64):
                scan_dict_table(table, slots)
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


def parse_int(s: str) -> int:
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def load_dump(path: pathlib.Path) -> Dump:
    meta: dict[str, int] = {}
    roots: list[tuple[int, int]] = []
    words: dict[int, int] = {}
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
    return Dump(meta, roots, Memory(words), str(path))


def pruned_granules(words: dict[int, int]) -> set[int]:
    """Granules whose map bit is set, from a memory image or dump."""
    out = set()
    for w in range(HEAP_LIMIT >> 11):
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
    # The RTL traces with the static prune map preloaded; its counters and
    # overflow follow that trace. The free set is always judged against the
    # unpruned trace, so an unsound map is a SAFETY failure here.
    kw = dict(spill_sp=m.get("spill_sp", RF_SPILL_BASE),
              exc_sp=m.get("exc_sp", EXC_STACK_BASE), frame_depth=m.get("frame_depth", 0),
              stack_limit=m.get("stack_limit"), onchip=m.get("onchip", 256), mutant=mutant,
              extra_roots=bool(m.get("extra_roots", 1)))
    pruned = {g for g in pruned_granules(dump.mem.words) if g < dyn_base >> 4}
    pruned |= compiler_idle_premark(dump.mem, dyn_base)
    res = trace(dump.mem, dump.roots, **kw)
    res_p = trace(dump.mem, dump.roots, pruned=pruned, **kw) if pruned else res
    if m.get("overflow", 0):
        if not res_p.overflow and m.get("stack_limit") is not None:
            problems.append("RTL reported mark-stack overflow but the oracle's stack fits")
        return problems
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
    want_all = all_free_runs(res, dyn_base, heap_limit)
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
    if got != want:
        want_free = {g for b, s in want for g in range(b >> 4, (b + s) >> 4)}
        got_free = {g for b, s in got for g in range(b >> 4, (b + s) >> 4)}
        unsafe = sorted(got_free - want_free)
        leak = sorted(want_free - got_free)
        if unsafe:
            problems.append(f"SAFETY: {len(unsafe)} reachable granules freed, first at "
                            f"{unsafe[0] << 4:#x} ({describe(res, unsafe[0] << 4)})")
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
    return problems


def describe(res: TraceResult, addr: int) -> str:
    for a, n, what in res.extents:
        if a <= addr < a + n:
            return f"{what} at {a:#x}+{n}"
    return "?"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", nargs="*", default=[], help="dump files or directories")
    ap.add_argument("--hw", action="store_true", help="also compare the mark-stack high-water mark")
    ap.add_argument("--mutant", type=int, default=0)
    ap.add_argument("--max", type=int, default=0, help="check at most N dumps per directory")
    args = ap.parse_args()
    paths: list[pathlib.Path] = []
    for p in map(pathlib.Path, args.check):
        if p.is_dir():
            found = sorted(p.glob("*.gcdump"), key=lambda x: x.name)
            paths += found[: args.max] if args.max else found
        else:
            paths.append(p)
    bad = 0
    for p in paths:
        problems = check_dump(load_dump(p), compare_hw=args.hw, mutant=args.mutant)
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
