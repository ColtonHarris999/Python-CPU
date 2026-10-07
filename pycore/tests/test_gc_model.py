"""G2: the GC oracle agrees with Python-level reachability (planning/gc_plan.md §10.2).

gc_model.trace() decodes a raw dmem image. gc_heapgen builds that image from a
Python object graph whose nodes record their own allocations and references,
so the expected live set here never decodes a heap word.
"""

from __future__ import annotations

import os
import unittest

from pycore.tools import gc_heapgen, gc_model
from pycore.tools.encoding import (
    EXC_STACK_BASE,
    FRAME_STACK_BASE,
    GC_COMPILER_CLEANUP,
    GC_COMPILER_CLEANUP_MAGIC,
    HEAP_BASE,
    HEAP_LIMIT,
    TAG_INT,
    TAG_OBJECT,
    int_value,
)

SEEDS = int(os.environ.get("GC_MODEL_SEEDS", "500"))


def oracle_live(h: gc_heapgen.Heap) -> tuple[set[int], gc_model.TraceResult]:
    mem = gc_model.Memory(dict(h.b.words))
    res = gc_model.trace(mem, h.reg_roots, spill_sp=h.spill_sp, exc_sp=h.exc_sp,
                         frame_depth=h.frame_depth)
    return {g for g in range(HEAP_LIMIT >> 4) if res.marked[g]}, res


def directed(maker: str, root_via: str = "reg") -> gc_heapgen.Heap:
    """One object of one kind, rooted one way, plus unrelated garbage."""
    g = gc_heapgen.Gen(seed=1234, size=0)
    g.long_str()                    # garbage before
    node = getattr(g, maker)()
    g.list_()                       # garbage after
    b = g.b
    root_nodes = [node]
    reg_roots: list[tuple[int, int]] = []
    exc_sp, depth = EXC_STACK_BASE, 0
    rows = {"nonptr"}
    if root_via == "reg":
        reg_roots = [node.handle, (TAG_INT, int_value(5))]
    elif root_via == "exc":
        b._write(EXC_STACK_BASE, 0)
        b._write(EXC_STACK_BASE + 16, (1 << 127) | (TAG_OBJECT << 120) | (node.handle[1] & ((1 << 64) - 1)))
        exc_sp = EXC_STACK_BASE + 32
        rows.add("EXC")
    elif root_via == "frame":
        b._write(FRAME_STACK_BASE, 0)
        b._write(FRAME_STACK_BASE + 16, node.handle[1] & 0xFFFFFFFF)
        depth = 1
        rows.add("FRAME")
    return gc_heapgen.Heap(b, g.nodes, reg_roots, root_nodes, 0x440, HEAP_LIMIT,
                           0x100000, exc_sp, depth, rows | g.rows)


DIRECTED = [
    ("long_str", "reg"), ("tuple_", "reg"), ("list_", "reg"), ("dict_", "reg"),
    ("set_", "reg"), ("bytearray_", "reg"), ("instance", "reg"), ("type_", "reg"),
    ("bound_method", "reg"), ("builtin", "reg"), ("exception", "exc"), ("cell", "reg"),
    ("function", "reg"), ("code", "frame"), ("range1", "reg"), ("str_spill", "reg"),
]


class TestGcModel(unittest.TestCase):
    def test_idle_compiler_premarks_are_reconstructed_from_descriptor(self) -> None:
        pyc_g = HEAP_BASE
        builtins = HEAP_BASE + 0x10
        busy = HEAP_BASE + 0x20
        dyn_base = HEAP_BASE + 0x100
        header = (
            (GC_COMPILER_CLEANUP_MAGIC << 96)
            | (1 << 64)
            | (busy << 32)
            | ((builtins >> 4) << 16)
            | (pyc_g >> 4)
        )
        mem = gc_model.Memory({GC_COMPILER_CLEANUP: header})
        self.assertEqual(
            gc_model.compiler_idle_premark(mem, dyn_base),
            {pyc_g >> 4, builtins >> 4},
        )
        mem.words[busy] = 1
        self.assertEqual(gc_model.compiler_idle_premark(mem, dyn_base), set())

    def check(self, h: gc_heapgen.Heap, label: str) -> None:
        got, res = oracle_live(h)
        want = h.expected_live()
        if got != want:
            extra = sorted(got - want)[:5]
            missing = sorted(want - got)[:5]
            self.fail(f"{label}: oracle retained {[hex(g << 4) for g in extra]} "
                      f"missed {[hex(g << 4) for g in missing]}")
        self.assertEqual((res.wild, res.bad_kind, res.reserved), (0, 0, 0), label)

    def test_oracle_matches_python_reachability(self) -> None:
        rows: set[str] = set()
        for seed in range(SEEDS):
            h = gc_heapgen.generate(seed)
            self.check(h, f"seed {seed}")
            rows |= h.reachable_rows()
        for maker, via in DIRECTED:
            h = directed(maker, via)
            self.check(h, f"directed {maker} via {via}")
            rows |= h.reachable_rows()
        covered = rows & set(gc_heapgen.ROWS)
        print(f"G2 seeds={SEEDS} directed={len(DIRECTED)} rows={len(covered)}/{len(gc_heapgen.ROWS)}")
        self.assertEqual(covered, set(gc_heapgen.ROWS))

    def test_precision_traps_are_not_retained(self) -> None:
        # Stale list capacity, deleted dict values, and INT payloads equal to
        # a live address keep nothing alive: every seed checks that already,
        # and this pins that the generator actually plants them.
        planted = 0
        for seed in range(40):
            h = gc_heapgen.generate(seed)
            for n in h.nodes:
                if n.kind == "LIST" and len(n.allocs) == 2:
                    obj, buf = n.allocs[0][0], n.allocs[1][0]
                    hdr = h.b.words.get(obj, 0)
                    if (hdr >> 64) > (hdr & ((1 << 64) - 1)):
                        planted += 1
        self.assertGreater(planted, 0)

    def test_bounded_stack_marks_the_same_set(self) -> None:
        # Chunked scans and the rescan list: a five-entry stack must reach
        # exactly what an unbounded one does, on random heaps (some with
        # containers wider than a chunk) and on a deep chain.
        rescanned = 0
        heaps = [(f"seed {s}", gc_heapgen.generate(s)) for s in range(min(SEEDS, 120))]
        g = gc_heapgen.Gen(seed=8, size=0)
        nxt = (TAG_INT, int_value(0))
        for i in range(400):
            nxt = g.b.alloc_tuple([g.b.alloc_list([(TAG_INT, int_value(i))]), nxt])
        heaps.append(("chain", gc_heapgen.Heap(g.b, g.nodes, [nxt], [], 0x440, HEAP_LIMIT,
                                               0x100000, EXC_STACK_BASE, 0, set())))
        for label, h in heaps:
            mem = gc_model.Memory(dict(h.b.words))
            kw = dict(spill_sp=h.spill_sp, exc_sp=h.exc_sp, frame_depth=h.frame_depth)
            free = gc_model.trace(mem, h.reg_roots, **kw)
            tight = gc_model.trace(mem, h.reg_roots, stack_limit=3, onchip=2,
                                   rescan_limit=4096, **kw)
            self.assertFalse(tight.overflow, label)
            self.assertLessEqual(tight.stack_hw, 5, label)
            self.assertEqual(tight.marked, free.marked, label)
            rescanned += tight.rescans > 0
        self.assertGreater(rescanned, len(heaps) // 2)
        # The chain needs one rescan entry at a time; a one-entry list holds.
        _, chain = heaps[-1]
        res = gc_model.trace(gc_model.Memory(dict(chain.b.words)), chain.reg_roots,
                             stack_limit=1, onchip=2, rescan_limit=1)
        self.assertFalse(res.overflow)


if __name__ == "__main__":
    unittest.main()
