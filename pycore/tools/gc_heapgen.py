#!/usr/bin/env python3
"""Random heap graphs for the GC oracle and engine tests (plan §10.2 G2, G3).

`generate(seed)` builds a dmem image with HeapImageBuilder from a random
object graph that covers every row of plan §4.1, then picks roots: register
roots plus the memory-resident ones (boot record, native-method table,
StopIteration sidecar, RF spill, exception-stack nodes, frame descriptors).

Each generated object is a `Node` that records, by construction, every
allocation it owns and the objects it references at the *Python level*.
`expected_live()` walks that graph, so G2 compares gc_model.py's traversal of
the raw image against reachability that never decodes a heap word.

Precision traps are planted on purpose: stale pointers in list capacity past
`length`, deleted dict/set entries (tombstone key, stale value kept), INT
payloads equal to live addresses, and garbage objects that point at live ones.
"""

from __future__ import annotations

import argparse
import pathlib
import random
import sys
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from encoding import (  # noqa: E402
    EXC_STACK_BASE,
    FRAME_STACK_BASE,
    GC_SCAN_CHUNK,
    HEAP_BASE,
    HEAP_LIMIT,
    MUT_DICT,
    NATIVE_METHOD_COUNT,
    OBK_BYTEARRAY,
    RF_SPILL_BASE,
    TAG_BOOL,
    TAG_CODE_OBJECT,
    TAG_CONTROL,
    TAG_FLOAT,
    TAG_INT,
    TAG_LONG_STR,
    TAG_MUT_COLLEC,
    TAG_OBJECT,
    TAG_TOMBSTONE,
    TAG_TUPLE,
    int_value,
    make_bytearray,
    make_none,
    mut_addr,
)
from heap_image import HeapImageBuilder, dict_min_slots, static_dict_slots  # noqa: E402
import gc_static  # noqa: E402

TAG_ITER = 5
TAG_RANGE = 11
OBK_CELL = 7
OBK_FUNCTION = 8
ITER_MAGIC = 0xA5
M64 = (1 << 64) - 1

# Rows of plan §4.1 (G2 coverage).
ROWS = [
    "nonptr", "LONG_STR", "TUPLE", "LIST", "DICT", "SET", "BYTEARRAY",
    "OBJECT", "CODE", "RANGE", "ITER", "FRAME", "EXC",
]


@dataclass(eq=False)
class Node:
    kind: str
    handle: tuple[int, int]
    allocs: list[tuple[int, int]] = field(default_factory=list)
    children: list["Node"] = field(default_factory=list)
    row: str = ""


@dataclass
class Heap:
    b: HeapImageBuilder
    nodes: list[Node]
    reg_roots: list[tuple[int, int]]        # tagged register roots
    root_nodes: list[Node]                  # nodes those roots and memory roots reference
    dyn_base: int
    heap_limit: int
    spill_sp: int
    exc_sp: int
    frame_depth: int
    rows: set[str]

    def expected_live(self) -> set[int]:
        seen: set[int] = set()
        live: set[int] = set()
        work = list(self.root_nodes)
        while work:
            n = work.pop()
            if id(n) in seen:
                continue
            seen.add(id(n))
            for a, ln in n.allocs:
                live.update(range(a >> 4, (a + ln - 1 >> 4) + 1))
            work.extend(n.children)
        return live

    def reachable_rows(self) -> set[str]:
        seen: set[int] = set()
        rows = set(self.rows)
        work = list(self.root_nodes)
        while work:
            n = work.pop()
            if id(n) in seen:
                continue
            seen.add(id(n))
            if n.row:
                rows.add(n.row)
            work.extend(n.children)
        return rows

    def write(self, out_dir: pathlib.Path, stem: str) -> dict[str, str]:
        out_dir.mkdir(parents=True, exist_ok=True)
        hexp = out_dir / f"{stem}.hex"
        rootp = out_dir / f"{stem}.roots"
        self.b.write_hex(hexp)
        rootp.write_text("".join(f"{t} {v:x}\n" for t, v in self.reg_roots), encoding="ascii")
        tail = (self.b.ptr + 15) & ~15
        return {
            "hex": str(hexp), "roots": str(rootp),
            # Unallocated tail: a legal kept run for the keep/rover cases.
            "keep": f"+KEEP_LO={tail} +KEEP_HI={self.heap_limit} +ROVER_ADDR={tail}"
                    if self.heap_limit > tail else "",
            "plusargs": (f"+DMEM_HEX={hexp} +ROOTS={rootp} +DYN_BASE={self.dyn_base} "
                         f"+HEAP_LIMIT={self.heap_limit} +SPILL_SP={self.spill_sp} "
                         f"+EXC_SP={self.exc_sp} +FRAME_DEPTH={self.frame_depth}"),
        }


class Gen:
    def __init__(self, seed: int, size: int = 60) -> None:
        self.r = random.Random(seed)
        self.seed = seed
        self.b = HeapImageBuilder()
        self.nodes: list[Node] = []
        self.size = size
        self.rows: set[str] = set()

    # ---- values ----
    def nonptr(self) -> tuple[int, int]:
        c = self.r.randrange(6)
        if c == 0:
            return (TAG_INT, int_value(self.r.randrange(-1000, 1000)))
        if c == 1 and self.nodes:
            # INT whose payload equals a heap address: must not be traced.
            n = self.r.choice(self.nodes)
            return (TAG_INT, n.handle[1] & M64)
        if c == 2:
            return (TAG_BOOL, self.r.randrange(2))
        if c == 3:
            return make_none()
        if c == 4:
            return (TAG_FLOAT, self.r.getrandbits(64))
        return self.b.alloc_str(self.r.choice(["a", "bc", "short"]))

    def pick(self, p_ptr: float = 0.7) -> tuple[tuple[int, int], Node | None]:
        """A value and the node it references (None for non-pointers)."""
        if self.nodes and self.r.random() < p_ptr:
            n = self.r.choice(self.nodes)
            return self.value_of(n), n
        return self.nonptr(), None

    def value_of(self, n: Node) -> tuple[int, int]:
        # Some references go through an iterator or range handle.
        if n.kind in ("LIST", "DICT", "SET") and self.r.random() < 0.15:
            k = {"LIST": 0, "DICT": 5, "SET": 6}[n.kind]
            self.rows.add("ITER")
            return (TAG_ITER, self.iter_val(k, 0, 0, mut_addr(n.handle[1])))
        if n.kind == "TUPLE" and self.r.random() < 0.15 and (n.handle[1] >> 64):
            self.rows.add("ITER")
            return (TAG_ITER, self.iter_val(1, 0, n.handle[1] >> 64, n.handle[1] & 0xFFFFFFFF))
        if n.kind == "INSTANCE" and self.r.random() < 0.15:
            self.rows.add("ITER")
            return (TAG_ITER, self.iter_val(4, 0, 0, n.handle[1] & 0xFFFFFFFF))
        if n.kind == "LONG_STR" and self.r.random() < 0.15:
            self.rows.add("ITER")
            return (TAG_ITER, self.iter_val(3, 0, 5, n.handle[1] & 0xFFFFFFFF))
        return n.handle

    @staticmethod
    def iter_val(kind: int, index: int, size: int, addr: int, aux: int = 0) -> int:
        return (ITER_MAGIC << 120) | (kind << 116) | (aux << 96) | (index << 64) | (size << 32) | addr

    def add(self, n: Node) -> Node:
        self.nodes.append(n)
        return n

    def kids(self, pairs: list[tuple[tuple[int, int], Node | None]]) -> list[Node]:
        return [n for _, n in pairs if n is not None]

    # ---- node builders ----
    def long_str(self) -> Node:
        text = "".join(self.r.choice("abcdefgh") for _ in range(self.r.randrange(16, 60)))
        if self.r.random() < 0.2:
            text += "\u0101"
        before = self.b.ptr
        h = self.b.alloc_str(text + str(len(self.nodes)), interned=False)
        addr = h[1] & 0xFFFFFFFF
        nbytes = (h[1] >> 96) & 0xFFFFFF
        assert addr >= before
        return self.add(Node("LONG_STR", h, [(addr, 16 + ((nbytes + 15) & ~15))], row="LONG_STR"))

    def tuple_(self, n: int | None = None) -> Node:
        n = self.r.randrange(0, 5) if n is None else n
        els = [self.pick() for _ in range(n)]
        h = self.b.alloc_tuple([v for v, _ in els])
        allocs = [(h[1] & 0xFFFFFFFF, n * 32)] if n else []
        return self.add(Node("TUPLE", h, allocs, self.kids(els), row="TUPLE"))

    def list_(self, n: int | None = None) -> Node:
        n = self.r.randrange(0, 5) if n is None else n
        cap = n + self.r.randrange(0, 3)
        els = [self.pick() for _ in range(n)]
        h = self.b.alloc_list_with_capacity([v for v, _ in els], cap)
        obj = mut_addr(h[1])
        buf = self.b.words.get(obj + 16, 0) & 0xFFFFFFFF
        allocs = [(obj, 32)] + ([(buf, cap * 32)] if cap else [])
        # Stale pointers past `length`: must not keep anything alive.
        for i in range(n, cap):
            if self.nodes:
                v = self.value_of(self.r.choice(self.nodes))
                self.b._write_tagged(buf + 32 * i, v[0], v[1])
        return self.add(Node("LIST", h, allocs, self.kids(els), row="LIST"))

    def key(self) -> tuple[tuple[int, int], Node | None]:
        c = self.r.randrange(5)
        if c == 0:
            return make_none(), None
        if c == 1:
            strs = [n for n in self.nodes if n.kind == "LONG_STR"]
            if strs:
                n = self.r.choice(strs)
                return n.handle, n
        if c == 2:
            return (TAG_FLOAT, self.r.getrandbits(64)), None
        return (TAG_INT, int_value(self.r.randrange(-50, 5000))), None

    def dict_(self, pairs_n: int | None = None) -> Node:
        n = self.r.randrange(0, 6) if pairs_n is None else pairs_n
        keys: list[tuple[tuple[int, int], Node | None]] = []
        seen_keys: set[tuple[int, int]] = set()
        while len(keys) < n:
            k = self.key()
            if k[0] not in seen_keys:
                seen_keys.add(k[0])
                keys.append(k)
        vals = [self.pick() for _ in range(n)]
        least = dict_min_slots(n) if n < 128 else static_dict_slots(n)
        slots = least if self.r.random() < 0.7 else max(4, least * 2)
        h = self.b.alloc_dict([(k[0], v[0]) for k, v in zip(keys, vals)], slot_count=slots)
        obj = mut_addr(h[1])
        ptrs = self.b.words[obj + 32]
        order, table = (ptrs >> 64) & 0xFFFFFFFF, ptrs & 0xFFFFFFFF
        allocs = [(obj, 48), (order, slots * 32), (table, slots * 64)]
        live = list(range(n))
        # Delete some entries: tombstone key tag, stale value kept, order shifted.
        if n and self.r.random() < 0.5:
            victim = self.r.choice(live)
            live.remove(victim)
            kv = keys[victim][0]
            for i in range(slots):
                s = table + 64 * i
                tw = self.b.words.get(s + 16, 0)
                if tw != 0 and (tw & 0xF) == kv[0] and self.b.words.get(s, 0) == (kv[1] & ((1 << 128) - 1)):
                    self.b._write(s + 16, TAG_TOMBSTONE)
                    break
            order_keys = [keys[i][0] for i in range(n) if i != victim]
            for i in range(slots):
                self.b._write(order + 32 * i, 0)
                self.b._write(order + 32 * i + 16, 0)
            for i, (t, v) in enumerate(order_keys):
                self.b._write_tagged(order + 32 * i, t, v)
            used = n - 1
            self.b._write(obj, (slots << 64) | used)
            self.b._write(obj + 16, (n << 64) | used)
        kids = [keys[i][1] for i in live if keys[i][1] is not None]
        kids += [vals[i][1] for i in live if vals[i][1] is not None]
        return self.add(Node("DICT", h, allocs, kids, row="DICT"))

    def set_(self, n: int | None = None) -> Node:
        n = self.r.randrange(0, 5) if n is None else n
        els: list[tuple[tuple[int, int], Node | None]] = []
        seen: set[tuple[int, int]] = set()
        while len(els) < n:
            k = self.key()
            if k[0] not in seen:
                seen.add(k[0])
                els.append(k)
        h = self.b.alloc_set([e[0] for e in els],
                             slot_count=static_dict_slots(n) if n >= 64 else None)
        obj = mut_addr(h[1])
        slots = (self.b.words[obj] >> 64) & 0xFFFFFFFF
        table = self.b.words[obj + 16] & 0xFFFFFFFF
        allocs = [(obj, 32)] + ([(table, slots * 32)] if slots else [])
        live = list(range(n))
        if n and self.r.random() < 0.4:
            victim = self.r.choice(live)
            live.remove(victim)
            ev = els[victim][0]
            for i in range(slots):
                s = table + 32 * i
                tw = self.b.words.get(s + 16, 0)
                if tw != 0 and (tw & 0xF) == ev[0] and self.b.words.get(s, 0) == (ev[1] & ((1 << 128) - 1)):
                    self.b._write(s + 16, TAG_TOMBSTONE)
                    break
            self.b._write(obj, (slots << 64) | (n - 1))
        kids = [els[i][1] for i in live if els[i][1] is not None]
        return self.add(Node("SET", h, allocs, kids, row="SET"))

    def type_(self) -> Node:
        d = self.dict_(self.r.randrange(0, 3))
        name = self.long_str() if self.r.random() < 0.5 else None
        bases = [n for n in self.nodes if n.kind == "TYPE"]
        base = self.r.choice(bases) if bases and self.r.random() < 0.5 else None
        h = self.b.alloc_type(name.handle if name else self.b.alloc_str("T"), tp_dict=d.handle,
                              tp_base=base.handle if base else None)
        kids = [d] + ([name] if name else []) + ([base] if base else [])
        return self.add(Node("TYPE", h, [(h[1] & 0xFFFFFFFF, 128)], kids, row="OBJECT"))

    def instance(self) -> Node:
        types = [n for n in self.nodes if n.kind == "TYPE"]
        t = self.r.choice(types) if types else self.type_()
        d = self.dict_(self.r.randrange(0, 4))
        h = self.b.alloc_instance(type_addr=t.handle[1] & 0xFFFFFFFF, idict=d.handle)
        return self.add(Node("INSTANCE", h, [(h[1] & 0xFFFFFFFF, 64)], [t, d], row="OBJECT"))

    def code(self) -> Node:
        consts = self.tuple_()
        names = self.tuple_(self.r.randrange(0, 3))
        varnames = self.tuple_(self.r.randrange(0, 2))
        defaults = self.tuple_(self.r.randrange(0, 2))
        kwd = self.dict_(self.r.randrange(0, 2))
        exct = self.tuple_(0)
        h = self.b.add_code_object(
            self.r.randrange(0, 4000), consts.handle, names.handle, varnames.handle,
            stacksize=4, nlocals=2, argcount=1, co_defaults=defaults.handle,
            co_kwdefaults=kwd.handle, co_exceptiontable=exct.handle)
        kids = [consts, names, varnames, defaults, kwd, exct]
        return self.add(Node("CODE", h, [(h[1] & 0xFFFFFFFF, 256)], kids, row="CODE"))

    def bound_method(self) -> Node:
        codes = [n for n in self.nodes if n.kind == "CODE"]
        f = self.r.choice(codes) if codes else self.code()
        v, sn = self.pick(0.9)
        h = self.b.alloc_bound_method(f.handle, v)
        return self.add(Node("BOUND", h, [(h[1] & 0xFFFFFFFF, 96)], [f] + ([sn] if sn else []),
                             row="OBJECT"))

    def builtin(self) -> Node:
        v, sn = self.pick(0.5)
        h = self.b.alloc_builtin(self.r.randrange(1, 20), v)
        return self.add(Node("BUILTIN", h, [(h[1] & 0xFFFFFFFF, 96)], [sn] if sn else [],
                             row="OBJECT"))

    def exception(self) -> Node:
        types = [n for n in self.nodes if n.kind == "TYPE"]
        t = self.r.choice(types) if types else self.type_()
        args = self.tuple_()
        h = self.b.alloc_exception(t.handle, args.handle)
        return self.add(Node("EXC", h, [(h[1] & 0xFFFFFFFF, 96)], [t, args], row="OBJECT"))

    def cell(self) -> Node:
        v, cn = self.pick(0.8)
        h = self.b._alloc_object(64, OBK_CELL, [v])
        return self.add(Node("CELL", h, [(h[1] & 0xFFFFFFFF, 64)], [cn] if cn else [], row="OBJECT"))

    def function(self) -> Node:
        codes = [n for n in self.nodes if n.kind == "CODE"]
        f = self.r.choice(codes) if codes else self.code()
        cells = [self.cell() for _ in range(self.r.randrange(0, 3))]
        clos_h = self.b.alloc_tuple([c.handle for c in cells])
        clos = self.add(Node("TUPLE", clos_h, [(clos_h[1] & 0xFFFFFFFF, 32 * len(cells))] if cells else [],
                             list(cells), row="TUPLE"))
        h = self.b._alloc_object(96, OBK_FUNCTION, [f.handle, clos_h])
        return self.add(Node("FUNC", h, [(h[1] & 0xFFFFFFFF, 96)], [f, clos], row="OBJECT"))

    def bytearray_(self) -> Node:
        length = self.r.randrange(0, 40)
        cap = length + self.r.randrange(0, 20)
        h = self.b.alloc_bytearray(length, capacity=cap)
        addr = mut_addr(h[1])
        buf = self.b.words.get(addr + 64, 0) & 0xFFFFFFFF
        allocs = [(addr, 128)] + ([(buf, (cap + 15) & ~15)] if cap else [])
        if self.r.random() < 0.5:
            h = (TAG_OBJECT, addr)   # legacy OBK_BYTEARRAY object handle
        return self.add(Node("BYTEARRAY", h, allocs, row="BYTEARRAY"))

    def range1(self) -> Node:
        t = self.b.alloc_tuple([(TAG_INT, int_value(x)) for x in (1, 1 << 40, 3)])
        tn = self.add(Node("TUPLE", t, [(t[1] & 0xFFFFFFFF, 96)], row="TUPLE"))
        h = (TAG_RANGE, (1 << 127) | (t[1] & 0xFFFFFFFF))
        return self.add(Node("RANGE", h, [], [tn], row="RANGE"))

    def str_spill(self) -> Node:
        addr = self.b._alloc(16)
        self.b._write(addr, self.r.getrandbits(120))
        h = (TAG_ITER, self.iter_val(3, 0, 3, addr, aux=1))
        return self.add(Node("STRSPILL", h, [(addr, 16)], row="ITER"))

    def wide(self) -> Node:
        """A tuple, list, dict or set wider than one GC scan chunk."""
        n = GC_SCAN_CHUNK + self.r.randrange(1, 2 * GC_SCAN_CHUNK)
        return self.r.choice([self.tuple_, self.list_, self.dict_, self.set_])(n)

    # ---- graph ----
    def build(self) -> list[Node]:
        makers = [self.long_str, self.tuple_, self.list_, self.dict_, self.set_, self.type_,
                  self.instance, self.code, self.bound_method, self.builtin, self.exception,
                  self.cell, self.function, self.bytearray_, self.range1, self.str_spill]
        if self.r.random() < 0.6:    # immutable cluster at the bottom (prunable when static)
            for _ in range(self.r.randrange(2, 5)):
                self.long_str()
            for _ in range(self.r.randrange(2, 6)):
                self.tuple_(self.r.randrange(1, 4))
            self.range1()
            if self.r.random() < 0.5:
                self.code()
        for mk in makers:            # every row at least once
            mk()
        # Chunked scans and their continuations (own RNG: the other seeds'
        # heaps stay as they were).
        if random.Random(self.seed ^ 0x51DE).random() < 0.3:
            self.wide()
        while len(self.nodes) < self.size:
            self.r.choice(makers)()
        # Back edges (cycles): patch mutable slots to reference later nodes.
        for _ in range(self.r.randrange(2, 8)):
            n = self.r.choice(self.nodes)
            t = self.r.choice(self.nodes)
            tv = self.value_of(t)
            if n.kind == "LIST" and n.children:
                obj = mut_addr(n.handle[1])
                length = self.b.words[obj] & 0xFFFFFFFF
                if length:
                    buf = self.b.words[obj + 16] & 0xFFFFFFFF
                    i = self.r.randrange(length)
                    old_tag = self.b.words.get(buf + 32 * i + 16, 0) & 0xF
                    # Only overwrite a non-pointer, so no existing edge is lost.
                    if old_tag in (TAG_CONTROL, TAG_INT, TAG_BOOL, TAG_FLOAT, 7):
                        self.b._write_tagged(buf + 32 * i, tv[0], tv[1])
                        n.children.append(t)
            elif n.kind == "CELL":
                a = n.handle[1] & 0xFFFFFFFF
                self.b._write_tagged(a + 32, tv[0], tv[1])
                n.children = [t]
        return self.nodes


def generate(seed: int, size: int | None = None) -> Heap:
    r = random.Random(seed ^ 0x5EED)
    g = Gen(seed, size or r.randrange(20, 90))
    nodes = g.build()
    b = g.b
    root_nodes: list[Node] = []
    reg_roots: list[tuple[int, int]] = []
    rows = set(g.rows)
    rows.add("nonptr")
    # Register roots.
    for _ in range(r.randrange(1, 10)):
        v, n = g.pick(0.6)
        reg_roots.append(v)
        if n is not None:
            root_nodes.append(n)
    # Boot record (module code, globals dict, builtins dict).
    codes = [n for n in nodes if n.kind == "CODE"]
    dicts = [n for n in nodes if n.kind == "DICT"]
    mod, glob, bi = r.choice(codes), r.choice(dicts), r.choice(dicts)
    b.write_boot_record(mod.handle, glob.handle, bi.handle)
    root_nodes += [mod, glob, bi]
    # Native-method table: code objects and STRACC sentinels.
    table = []
    for i in range(NATIVE_METHOD_COUNT):
        if r.random() < 0.5:
            c = r.choice(codes)
            table.append(c.handle)
            root_nodes.append(c)
        else:
            table.append((TAG_CODE_OBJECT, 0xFFFF0000 | i))
    b.write_native_method_table(table)
    # StopIteration sidecar.
    objs = [n for n in nodes if n.kind in ("TYPE", "INSTANCE")]
    si = r.choice(objs)
    b.write_iter_exhaust_type(si.handle)
    root_nodes.append(si)
    # RF spill prefix.
    n_spill = r.randrange(0, 6)
    for i in range(n_spill):
        v, n = g.pick(0.7)
        b._write_tagged(RF_SPILL_BASE + 32 * i, v[0], v[1])
        if n is not None:
            root_nodes.append(n)
    # Exception-stack nodes: slot1 {valid, tag, addr}.
    n_exc = r.randrange(0, 4)
    excs = [n for n in nodes if n.kind in ("EXC", "INSTANCE")]
    for i in range(n_exc):
        node = EXC_STACK_BASE + 32 * i
        b._write(node, 0)
        if r.random() < 0.7 and excs:
            e = r.choice(excs)
            b._write(node + 16, (1 << 127) | (TAG_OBJECT << 120) | (e.handle[1] & M64))
            root_nodes.append(e)
            rows.add("EXC")
        else:
            b._write(node + 16, 0)
    # Frame descriptors: slot1 {globals[127:97], inst[96:33], ret[32], code[31:0]}.
    depth = r.randrange(0, 4)
    insts = [n for n in nodes if n.kind == "INSTANCE"]
    for k in range(depth):
        c = r.choice(codes)
        w = c.handle[1] & 0xFFFFFFFF
        root_nodes.append(c)
        if insts and r.random() < 0.4:
            inst = r.choice(insts)
            w |= (inst.handle[1] & M64) << 33
            root_nodes.append(inst)
        if r.random() < 0.7:
            d = r.choice(dicts)
            w |= (mut_addr(d.handle[1]) & 0x7FFFFFFF) << 97
            root_nodes.append(d)
        b._write(FRAME_STACK_BASE + 32 * k, 0)
        b._write(FRAME_STACK_BASE + 32 * k + 16, w)
        rows.add("FRAME")
    # Dynamic-region split: everything below dyn_base is pinned.
    start_addrs = sorted(a for n in nodes for a, _ in n.allocs)
    split = r.choice(start_addrs[: max(1, len(start_addrs) // 3)]) if r.random() < 0.5 else HEAP_BASE
    heap_limit = min(HEAP_LIMIT, ((b.ptr + 15) & ~15) + 16 * r.randrange(0, 64))
    if split > HEAP_BASE and r.random() < 0.75:
        b.words.update(gc_static.prune_map(b.words, split, reg_roots))
    return Heap(b, nodes, reg_roots, root_nodes, split, heap_limit,
                RF_SPILL_BASE + 32 * n_spill, EXC_STACK_BASE + 32 * n_exc, depth, rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", default="build/gc_heapgen")
    args = ap.parse_args()
    h = generate(args.seed)
    info = h.write(pathlib.Path(args.out), f"seed{args.seed}")
    print(info["plusargs"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
