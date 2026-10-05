"""Static-image prune map for the GC (pycore/docs/gc.md §"Static image").

Every image carries a large pinned static region (the firmware compiler and
ROM builtins, about 380 KB). Most of it is immutable: code objects, their
tuples, strings. An immutable static object can only reference static
objects, so if nothing in its static subgraph can be mutated at run time it
can never lead to a dynamic object, and the collector need not trace it.

`prune_map(words, dyn_base)` returns {word_addr: bits}: bit g of the map is
set iff granule g starts a static object whose subgraph holds no runtime-
mutable object. The image builder stores the map at PYCORE_GC_STATIC_MAP;
the engine preloads it into the mark bitmap at the start of every
collection, so pruned objects test as already marked.

Runtime-mutable: lists, sets, dicts (except the co_kwdefaults dict of a code
object, which no Python code can reach), cells. Instances are immutable but
reach their __dict__. The oracle (gc_model.py) keeps checking the unpruned
live set, so a wrong classification shows up as a G4 safety failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from encoding import (  # noqa: E402
    OBK_TYPE,
    BOOT_RECORD_ADDR,
    GC_STATIC_MAP,
    GC_STATIC_MAP_BYTES,
    HEAP_BASE,
    ITER_EXHAUST_TYPE_ADDR,
    MEMORY_ERROR_INSTANCE_ADDR,
    NATIVE_METHOD_COUNT,
    NATIVE_METHOD_TABLE_ADDR,
)
import gc_model as gm  # noqa: E402

M32 = (1 << 32) - 1


def static_graph(words: dict[int, int], dyn_base: int,
                 extra_roots: list[tuple[int, int]] = (),
                 frozen_type_dicts: bool = False):
    """Nodes (first-granule address) of the static objects reachable from
    the image's boot roots (and `extra_roots`), with their static children
    and mutability. `frozen_type_dicts`: the program cannot reach a type's
    dict (it names none of `__dict__`, `setattr`, `delattr`, `vars`,
    `compile`, `exec`, `eval`), so a TYPE's `tp_dict` is immutable."""
    mem = gm.Memory(words)
    kind_of: dict[int, str] = {}
    children: dict[int, list[int]] = {}
    mutable: set[int] = set()
    work: list[tuple[str, int, int]] = []

    def is_static(a: int) -> bool:
        return HEAP_BASE <= a < dyn_base and (a & 15) == 0

    def node_of(tag: int, val: int) -> tuple[str, int, int] | None:
        a = val & M32
        if tag == gm.TAG_LONG_STR:
            return ("STR", a, 0)
        if tag == gm.TAG_TUPLE and (val >> 64):
            return ("TUPLE", a, val >> 64)
        if tag == gm.TAG_MUT:
            mk = (val >> 124) & 0xF
            return {1: ("LIST", a, 0), 2: ("DICT", a, 0), 3: ("SET", a, 0),
                    4: ("OBJ", a, 0)}.get(mk)
        if tag == gm.TAG_OBJECT:
            return ("OBJ", a, 0)
        if tag == gm.TAG_CODE and not gm.is_stracc_method_code(a):
            return ("CODE", a, 0)
        if tag == gm.TAG_RANGE and (val >> 127) & 1:
            return ("TUPLE", a, 3)
        if tag == gm.TAG_ITER and (val >> 120) & 0xFF == gm.ITER_MAGIC:
            ik = (val >> 116) & 0xF
            if ik == gm.ITER_LIST:
                return ("LIST", a, 0)
            if ik == gm.ITER_TUPLE and (val >> 32) & M32:
                return ("TUPLE", a, (val >> 32) & M32)
            if ik == gm.ITER_STR:
                return None if (val >> 96) & 1 else ("STR", a, 0)
            if ik == gm.ITER_HEAP:
                return ("OBJ", a, 0)
            if ik == gm.ITER_DICT:
                return ("DICT", a, 0)
            if ik == gm.ITER_SET:
                return ("SET", a, 0)
        return None

    def add(parent: int | None, tag: int, val: int, frozen: bool = False) -> None:
        n = node_of(tag, val)
        if n is None:
            return
        kind, a, size = n
        if not is_static(a):
            # Only a mutable object should point outside the static image;
            # keep anything else that does.
            if parent is not None:
                mutable.add(parent)
            return
        if parent is not None:
            children[parent].append(a)
        if a in kind_of:
            return
        kind_of[a] = kind
        children[a] = []
        if kind in ("LIST", "SET", "DICT") and not frozen:
            mutable.add(a)
        work.append((kind, a, size))

    def slots(base: int, count: int, stride: int = 32):
        for i in range(count):
            s = base + stride * i
            yield mem.rd(s + 16) & 0xF, mem.rd(s)

    for base, n in ((BOOT_RECORD_ADDR, 3), (NATIVE_METHOD_TABLE_ADDR, NATIVE_METHOD_COUNT),
                    (ITER_EXHAUST_TYPE_ADDR, 1), (MEMORY_ERROR_INSTANCE_ADDR, 1)):
        for tag, val in slots(base, n):
            add(None, tag, val)
    for tag, val in extra_roots:
        add(None, tag, val)

    while work:
        kind, a, size = work.pop()
        if kind == "TUPLE":
            for tag, val in slots(a, size):
                add(a, tag, val)
        elif kind == "CODE":
            for i, (tag, val) in enumerate(slots(a, 8)):
                add(a, tag, val, frozen=(i == 6))
        elif kind == "LIST":
            hdr = mem.rd(a)
            buf = mem.rd(a + 16) & M32
            for tag, val in slots(buf, hdr & M32):
                add(a, tag, val)
        elif kind == "SET":
            n_slots = (mem.rd(a) >> 64) & M32
            table = mem.rd(a + 16) & M32
            if table:
                for tag, val in slots(table, n_slots):
                    add(a, tag, val)
        elif kind == "DICT":
            n_slots = (mem.rd(a) >> 64) & M32
            order_len = mem.rd(a + 16) & M32
            ptrs = mem.rd(a + 32)
            order, table = (ptrs >> 64) & M32, ptrs & M32
            if order:
                for tag, val in slots(order, order_len):
                    add(a, tag, val)
            if table:
                for i in range(n_slots):
                    s = table + 64 * i
                    ktw = mem.rd(s + 16)
                    if ktw == 0 or (ktw & 0xF) == gm.TAG_TOMBSTONE or \
                            ((ktw & 0xF) == 0 and ((ktw >> 4) & 0xF) == 0):
                        continue
                    add(a, ktw & 0xF, mem.rd(s))
                    add(a, mem.rd(s + 48) & 0xF, mem.rd(s + 32))
        elif kind == "OBJ":
            head = mem.rd(a)
            ob_kind = head >> 96
            if ob_kind == 7:          # OBK_CELL: contents can be rebound
                mutable.add(a)
            ext = gm.OBK_EXTENT.get(ob_kind, 0)
            ob_type = head & ((1 << 64) - 1)
            if ob_type:
                add(a, gm.TAG_OBJECT, ob_type)
            if ext and ob_kind != gm.OBK_BYTEARRAY:
                for i, (tag, val) in enumerate(slots(a + 32, (ext - 32) // 32)):
                    add(a, tag, val, frozen=(frozen_type_dicts and ob_kind == OBK_TYPE and i == 0))
    return kind_of, children, mutable


def kept_objects(words: dict[int, int], dyn_base: int,
                 extra_roots: list[tuple[int, int]] = (),
                 frozen_type_dicts: bool = False) -> tuple[dict[int, str], set[int]]:
    """(kind_of, keep): every static object, and those the map must not prune."""
    kind_of, children, mutable = static_graph(words, dyn_base, extra_roots, frozen_type_dicts)
    parents: dict[int, list[int]] = {a: [] for a in kind_of}
    for a, kids in children.items():
        for k in kids:
            parents[k].append(a)
    keep = set(mutable)
    work = list(mutable)
    while work:
        a = work.pop()
        for p in parents[a]:
            if p not in keep:
                keep.add(p)
                work.append(p)
    return kind_of, keep


def kept_dict_values(words: dict[int, int], dyn_base: int, dict_addr: int,
                     exclude: set[int], frozen_type_dicts: bool = False) -> list[tuple[int, int]]:
    """Root handles covering every value in the static dict at `dict_addr`
    whose object the prune map keeps (minus `exclude`, by address).

    A kept TYPE is rooted through its fields rather than itself: its tp_dict
    always, and its other fields (base, name, ob_type) only when kept and not
    already a value of this dict. A collection then does not re-read every
    type object (G13 P6a)."""
    mem = gm.Memory(words)
    _, keep = kept_objects(words, dyn_base, frozen_type_dicts=frozen_type_dicts)
    n_slots = (mem.rd(dict_addr) >> 64) & M32
    table = mem.rd(dict_addr + 32) & M32
    vals = []
    for i in range(n_slots if table else 0):
        s = table + 64 * i
        ktw = mem.rd(s + 16)
        if ktw == 0 or (ktw & 0xF) == gm.TAG_TOMBSTONE:
            continue
        tag, val = mem.rd(s + 48) & 0xF, mem.rd(s + 32)
        a = val & M32
        if tag in gm.PTR_TAGS and a in keep and a not in exclude:
            vals.append((tag, val))
    covered = {v & M32 for _, v in vals}
    out: list[tuple[int, int]] = []
    seen: set[int] = set()

    def put(tag: int, val: int) -> None:
        if (val & M32) not in seen:
            seen.add(val & M32)
            out.append((tag, val))

    for tag, val in vals:
        a = val & M32
        if tag == gm.TAG_OBJECT and (mem.rd(a) >> 96) == OBK_TYPE:
            ob_type = mem.rd(a) & M32
            if ob_type in keep and ob_type not in covered:
                put(gm.TAG_OBJECT, ob_type)
            for k in range(3):     # tp_dict, tp_base, tp_name
                ftag, fval = mem.rd(a + 48 + 32 * k) & 0xF, mem.rd(a + 32 + 32 * k)
                fa = fval & M32
                if ftag in gm.PTR_TAGS and fa in keep and (k == 0 or fa not in covered):
                    put(ftag, fval)
        else:
            put(tag, val)
    return out


def prune_map(words: dict[int, int], dyn_base: int,
              extra_roots: list[tuple[int, int]] = (),
              frozen_type_dicts: bool = False) -> dict[int, int]:
    """{map word address: 128-bit word} for the pruned static objects.

    The map has one bit per granule below GC_STATIC_MAP_BYTES * 8 * 16
    (1 MB). A static object above that is not pruned: the engine traces it.
    Writing on would put map words in the run table, which the sweep
    overwrites."""
    kind_of, keep = kept_objects(words, dyn_base, extra_roots, frozen_type_dicts)
    out: dict[int, int] = {}
    for a in kind_of:
        if a in keep:
            continue
        g = a >> 4
        if 16 * (g >> 7) >= GC_STATIC_MAP_BYTES:
            continue
        w = GC_STATIC_MAP + 16 * (g >> 7)
        out[w] = out.get(w, 0) | (1 << (g & 127))
    return out
