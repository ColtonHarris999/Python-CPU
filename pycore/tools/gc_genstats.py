#!/usr/bin/env python3.14
"""Generational statistics from a sequence of PyCore GC dumps.

Generational GC plan, Phase 0. Run a program with periodic collections and
dumps (for example `+GC_EN=1 +GC_AT_BOUNDARY_EVERY=40000 +GC_DUMP_EACH=<dir>
+GC_DUMP_MAX=1000`), then:

    python3.14 pycore/tools/gc_genstats.py <dir>
    make pycore-gc-genstats DUMPS=<dir>

For consecutive collections i-1, i it reports what a sticky-mark-bit minor
collection at i would have done if every object live at i-1 were old:
young survivors, allocation since i-1, the remembered set (old owners with a
pointer to a young object), and old objects that died (tenured garbage).
"""
from __future__ import annotations

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_model as g  # noqa: E402

M32 = g.M32
M64 = g.M64


def build_graph(d: g.Dump):
    """Return {owner: (kind, bytes, slots, [child owners])} for everything reachable."""
    mem = d.mem
    m = d.meta
    objs: dict[int, list] = {}
    work: list[tuple[int, int, int]] = []  # (kind, addr, size)

    def valid(a, n):
        return (a & 15) == 0 and g.HEAP_BASE <= a < g.HEAP_LIMIT and n <= g.HEAP_LIMIT - a

    def child(tag, val, parent):
        a = val & M32
        ent = None
        if tag == g.TAG_LONG_STR:
            n = 16 + g.pad16((val >> 96) & 0xFFFFFF)
            ent = ("STR", a, n, 0)
        elif tag == g.TAG_TUPLE:
            size = val >> 64
            if size and not size >> 32:
                ent = ("TUPLE", a, size * 32, size)
        elif tag == g.TAG_MUT:
            mk = (val >> 124) & 0xF
            ent = {g.MUT_LIST: ("LIST", a, 32, 0), g.MUT_DICT: ("DICT", a, 48, 0),
                   g.MUT_SET: ("SET", a, 32, 0), g.MUT_BYTEARRAY: ("OBJ", a, 16, 0)}.get(mk)
        elif tag == g.TAG_OBJECT:
            ent = ("OBJ", a, 16, 0)
        elif tag == g.TAG_CODE:
            if not g.is_stracc_method_code(a):
                ent = ("CODE", a, g.CODE_OBJECT_BYTES, 0)
        elif tag == g.TAG_RANGE:
            if (val >> 127) & 1:
                ent = ("TUPLE", a, 96, 3)
        elif tag == g.TAG_ITER:
            if (val >> 120) & 0xFF != g.ITER_MAGIC:
                return
            ik = (val >> 116) & 0xF
            if ik == g.ITER_LIST:
                ent = ("LIST", a, 32, 0)
            elif ik == g.ITER_TUPLE:
                size = (val >> 32) & M32
                if size:
                    ent = ("TUPLE", a, size * 32, size)
            elif ik == g.ITER_STR and a:
                ent = ("STR", a, 16, 0) if (val >> 96) & 1 else ("STRH", a, 16, 0)
            elif ik == g.ITER_HEAP:
                ent = ("OBJ", a, 16, 0)
            elif ik == g.ITER_DICT:
                ent = ("DICT", a, 48, 0)
            elif ik == g.ITER_SET:
                ent = ("SET", a, 32, 0)
        if ent is None or not a or not valid(a, ent[2]):
            return
        if parent is not None:
            objs[parent][3].append(a)
        if a in objs:
            return
        kind, addr, n, slots = ent
        objs[a] = [kind, n, slots, []]
        work.append((kind, addr, slots))

    def scan_plain(base, count, parent):
        for i in range(count):
            tag = mem.rd(base + 32 * i + 16) & 0xF
            if tag in g.PTR_TAGS:
                child(tag, mem.rd(base + 32 * i), parent)

    def scan_dict(base, slots, parent):
        for i in range(slots):
            s = base + 64 * i
            ktw = mem.rd(s + 16)
            kt = ktw & 0xF
            if ktw == 0 or (kt == g.TAG_CONTROL and ((ktw >> 4) & 0xF) == g.CTL_UNINIT) or kt == g.TAG_TOMBSTONE:
                continue
            if kt in g.PTR_TAGS:
                child(kt, mem.rd(s), parent)
            vt = mem.rd(s + 48) & 0xF
            if vt in g.PTR_TAGS:
                child(vt, mem.rd(s + 32), parent)

    for tag, val in d.roots:
        child(tag, val, None)
    scan_plain(g.BOOT_RECORD_ADDR, 3, None)
    scan_plain(g.NATIVE_METHOD_TABLE_ADDR, g.NATIVE_METHOD_COUNT, None)
    scan_plain(g.ITER_EXHAUST_TYPE_ADDR, 1, None)
    scan_plain(g.MEMORY_ERROR_INSTANCE_ADDR, 1, None)
    if m.get("extra_roots", 1):
        scan_plain(g.GC_EXTRA_ROOTS, g.GC_EXTRA_ROOTS_COUNT, None)
    scan_plain(g.RF_SPILL_BASE, (m.get("spill_sp", g.RF_SPILL_BASE) - g.RF_SPILL_BASE) >> 5, None)
    for node in range(g.EXC_STACK_BASE, m.get("exc_sp", g.EXC_STACK_BASE), 32):
        w = mem.rd(node + 16)
        if (w >> 127) & 1:
            t = (w >> 120) & 0xF
            if t in (g.TAG_OBJECT, g.TAG_CODE):
                child(t, w & M64, None)
    for k in range(m.get("frame_depth", 0)):
        w = mem.rd(g.FRAME_STACK_BASE + 32 * k + 16)
        if w & M32:
            child(g.TAG_CODE, w & M32, None)
        inst = (w >> 33) & M64
        if inst:
            child(g.TAG_OBJECT, inst, None)
        glob = (w >> 97) & ((1 << 31) - 1)
        if glob:
            child(g.TAG_MUT, (g.MUT_DICT << 124) | glob, None)

    while work:
        kind, a, size = work.pop()
        o = objs[a]
        if kind == "TUPLE":
            scan_plain(a, size, a)
        elif kind == "CODE":
            scan_plain(a, 8, a)
            o[2] = 8
        elif kind == "LIST":
            hdr = mem.rd(a)
            cap, length = (hdr >> 64) & M32, hdr & M32
            buf = mem.rd(a + 16) & M32
            o[2] = 1
            if cap and buf:
                objs[buf] = ["LBUF", cap * 32, length, []]
                o[3].append(buf)
                scan_plain(buf, length, buf)
        elif kind == "SET":
            slots = (mem.rd(a) >> 64) & M32
            table = mem.rd(a + 16) & M32
            o[2] = 1
            if slots and table:
                objs[table] = ["SBUF", slots * 32, slots, []]
                o[3].append(table)
                scan_plain(table, slots, table)
        elif kind == "DICT":
            slots = (mem.rd(a) >> 64) & M32
            order_len = mem.rd(a + 16) & M32
            ptrs = mem.rd(a + 32)
            order, table = (ptrs >> 64) & M32, ptrs & M32
            o[2] = 1
            if slots and order:
                objs[order] = ["DORD", slots * 32, order_len, []]
                o[3].append(order)
                scan_plain(order, order_len, order)
            if slots and table:
                objs[table] = ["DTAB", slots * 64, slots, []]
                o[3].append(table)
                scan_dict(table, slots, table)
        elif kind == "OBJ":
            head = mem.rd(a)
            ob_kind = head >> 96
            ext = g.OBK_EXTENT.get(ob_kind, 0)
            o[1] = max(ext, 16)
            ob_type = head & M64
            if ob_type:
                child(g.TAG_OBJECT, ob_type, a)
            if ob_kind == g.OBK_BYTEARRAY:
                cap = mem.rd(a + 96) & M32
                o[1] += g.pad16(cap)
            elif ext:
                scan_plain(a + 32, (ext - 32) // 32, a)
                o[2] = (ext - 32) // 32
        elif kind == "STRH":
            n = (mem.rd(a) >> 96) & 0xFFFFFF
            o[1] = 16 + g.pad16(n)
    return objs


def nat(p: pathlib.Path) -> int:
    return int(re.search(r"(\d+)", p.stem).group(1))


def main(dirpath: str, skip_explicit: bool = False, quiet: bool = False):
    dumps = sorted(pathlib.Path(dirpath).glob("*.gcdump"), key=nat)
    prev = None
    prev_live = None
    rows = []
    tot = dict(alloc=0, young=0, full_obj=0, minor_obj=0, full_slots=0, minor_slots=0,
               rem=0, tenured_dead=0, n=0)
    for p in dumps:
        d = g.load_dump(p)
        dyn = d.meta["dyn_base"]
        objs = build_graph(d)
        dynobjs = {a: o for a, o in objs.items() if a >= dyn}
        live = sum(o[1] for o in dynobjs.values())
        if prev is not None:
            def same(a):
                q = prev.get(a)
                return q is not None and q[0] == objs[a][0]
            old = {a for a in dynobjs if same(a)}
            young = [a for a in dynobjs if a not in old]
            ybytes = sum(dynobjs[a][1] for a in young)
            died_old = sum(o[1] for a, o in prev.items() if a >= dyn and not (a in objs and objs[a][0] == o[0]))
            reclaimed = d.meta.get("reclaimed", 0)
            alloc = d.meta["live"] - prev_live + reclaimed
            youngset = set(young)
            rem = [a for a, o in objs.items() if (a < dyn or a in old) and any(c in youngset for c in o[3])]
            rem_slots = sum(max(objs[a][2], 1) for a in rem)
            full_slots = sum(max(o[2], 1) for a, o in objs.items() if a >= dyn)
            minor_slots = sum(max(objs[a][2], 1) for a in young) + rem_slots
            rows.append((nat(p), d.meta.get("live"), alloc, ybytes, len(dynobjs), len(young), len(rem),
                         rem_slots, full_slots, minor_slots, died_old))
            if alloc > 0:
                tot["alloc"] += alloc
                tot["young"] += ybytes
            tot["full_obj"] += len(objs)
            tot["minor_obj"] += len(young) + len(rem)
            tot["full_slots"] += full_slots
            tot["minor_slots"] += minor_slots
            tot["rem"] += len(rem)
            tot["tenured_dead"] += died_old
            tot["n"] += 1
        prev, prev_live = objs, d.meta["live"]
    if quiet:
        return rows
    print(f"{'gc':>4} {'live':>8} {'alloc':>9} {'young_srv':>9} {'srv%':>6} {'dynobj':>7} {'young':>6} "
          f"{'remset':>6} {'rem_slot':>8} {'full_slot':>9} {'minor_slot':>10} {'old_died':>8}")
    for r in rows:
        srv = 100.0 * r[3] / r[2] if r[2] > 0 else float("nan")
        print(f"{r[0]:>4} {r[1]:>8} {r[2]:>9} {r[3]:>9} {srv:>6.1f} {r[4]:>7} {r[5]:>6} {r[6]:>6} "
              f"{r[7]:>8} {r[8]:>9} {r[9]:>10} {r[10]:>8}")
    if tot["n"]:
        print(f"TOTAL n={tot['n']} alloc={tot['alloc']} young_survived={tot['young']} "
              f"survival={100.0 * tot['young'] / max(tot['alloc'], 1):.2f}% "
              f"objects full={tot['full_obj']} minor={tot['minor_obj']} "
              f"slots full={tot['full_slots']} minor={tot['minor_slots']} "
              f"ratio={tot['minor_slots'] / max(tot['full_slots'], 1):.3f} "
              f"remset_avg={tot['rem'] / tot['n']:.1f} tenured_dead={tot['tenured_dead']}")


if __name__ == "__main__":
    main(sys.argv[1])
