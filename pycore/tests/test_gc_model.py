"""G2: the GC oracle agrees with Python-level reachability (planning/gc_plan.md §10.2).

gc_model.trace() decodes a raw dmem image. gc_heapgen builds that image from a
Python object graph whose nodes record their own allocations and references,
so the expected live set here never decodes a heap word.
"""

from __future__ import annotations

import os
import random
import unittest

from pycore.tools import gc_heapgen, gc_model
from pycore.tools.encoding import (
    EXC_STACK_BASE,
    FRAME_STACK_BASE,
    GC_COMPILER_CLEANUP,
    GC_COMPILER_CLEANUP_MAGIC,
    GC_FREE_MAGIC,
    HEAP_BASE,
    HEAP_LIMIT,
    TAG_INT,
    TAG_OBJECT,
    int_value,
)

SEEDS = int(os.environ.get("GC_MODEL_SEEDS", "500"))
GEN_SEEDS = min(SEEDS, 300)
M32 = (1 << 32) - 1


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


# --------------------------------------------------------------------------
# Generational minor collections (generational GC plan §4, Phase 1)
# --------------------------------------------------------------------------

def header(n: gc_heapgen.Node) -> int | None:
    """The address the engine pushes for n (its first allocation), or None
    for a node with no storage (an empty tuple, a small range)."""
    return n.allocs[0][0] if n.allocs else None


def entry(n: gc_heapgen.Node) -> tuple[int, int, int] | None:
    """The remset entry the barrier would log for owner n."""
    tag, val = n.handle
    a = val & M32
    g = gc_model
    if tag == g.TAG_TUPLE and val >> 64:
        return (g.K_TUPLE, a, val >> 64)
    if tag == g.TAG_MUT:
        k = {g.MUT_LIST: g.K_LIST, g.MUT_DICT: g.K_DICT, g.MUT_SET: g.K_SET,
             g.MUT_BYTEARRAY: g.K_OBJ}.get((val >> 124) & 0xF)
        return (k, a, 0) if k is not None else None
    if tag == g.TAG_OBJECT:
        return (g.K_OBJ, a, 0)
    if tag == g.TAG_CODE:
        return (g.K_CODE, a, 0)
    return None


def mark(bm: bytearray, a: int, ln: int) -> None:
    bm[a >> 4:((a + ln - 1) >> 4) + 1] = b"\x01" * (((a + ln - 1) >> 4) + 1 - (a >> 4))


class GenCase:
    """A random heap with a random old set and remembered set.

    About a third of the nodes, half, or most are old. Some old lists, dicts
    and sets have only their header old: their buffer or table was replaced
    since the last collection (young), which only a logged owner keeps."""

    def __init__(self, seed: int, h: gc_heapgen.Heap | None = None) -> None:
        self.h = h or gc_heapgen.generate(seed)
        r = random.Random(seed ^ 0x6E6E)
        self.old = bytearray(HEAP_LIMIT >> 4)
        self.replaced: set[int] = set()
        p = r.choice([0.3, 0.5, 0.85])
        for n in self.h.nodes:
            if n.allocs and r.random() < p:
                allocs = n.allocs
                if n.kind in ("LIST", "DICT", "SET") and len(allocs) > 1 and r.random() < 0.3:
                    allocs = allocs[:1]
                    self.replaced.add(id(n))
                for a, ln in allocs:
                    mark(self.old, a, ln)
        self.full = self.reach()
        owners = [n for n in self.h.nodes if self.is_old(n) and entry(n)]
        self.gap_nodes = [n for n in self.h.nodes if id(n) in self.full and self.needs_log(n)]
        self.rem_nodes = r.sample(owners, r.randrange(0, len(owners) + 1)) if owners else []

    def is_old(self, n: gc_heapgen.Node) -> bool:
        a = header(n)
        return a is not None and bool(self.old[a >> 4])

    def needs_log(self, n: gc_heapgen.Node) -> bool:
        """An old owner holding a young dynamic object or a young buffer."""
        if not self.is_old(n):
            return False
        dyn = self.h.dyn_base
        return ((id(n) in self.replaced and any(a >= dyn for a, _ in n.allocs[1:]))
                or any(header(c) >= dyn and not self.is_old(c) for c in self.refs(n)))

    def refs(self, n: gc_heapgen.Node):
        """The nodes with storage that n's slots reach: a node without
        storage (a range handle) is transparent."""
        work = list(n.children)
        while work:
            c = work.pop()
            if header(c) is None:
                work.extend(c.children)
            else:
                yield c

    def reach(self) -> set[int]:
        seen: set[int] = set()
        work = list(self.h.root_nodes)
        while work:
            n = work.pop()
            if id(n) not in seen:
                seen.add(id(n))
                work.extend(n.children)
        return seen

    def minor_live(self, rem_nodes: list[gc_heapgen.Node]) -> set[int]:
        """Python-level minor: old granules stay; young nodes are reached from
        the roots and from the remembered owners, which are scanned whether
        or not they are old; any other old node stops the walk."""
        live = set(gc_model._ones(self.old))
        seen: set[int] = set()
        work = [(n, False) for n in self.h.root_nodes] + [(n, True) for n in rem_nodes]
        while work:
            n, forced = work.pop()
            if id(n) in seen or (not forced and self.is_old(n)):
                continue
            seen.add(id(n))
            for a, ln in n.allocs:
                live.update(range(a >> 4, ((a + ln - 1) >> 4) + 1))
            work.extend((c, False) for c in n.children)
        return live

    def kw(self) -> dict:
        h = self.h
        return dict(spill_sp=h.spill_sp, exc_sp=h.exc_sp, frame_depth=h.frame_depth)

    def mem(self) -> gc_model.Memory:
        return gc_model.Memory(dict(self.h.b.words))

    def remset(self, nodes: list[gc_heapgen.Node]) -> list[tuple[int, int, int]]:
        return [entry(n) for n in nodes]


def make_dump(h: gc_heapgen.Heap, live: set[int], **meta: int) -> gc_model.Dump:
    """A dump whose run list frees exactly the dynamic granules not in
    `live` (runs of 64 B or more, headers written in the runs)."""
    words = dict(h.b.words)
    runs, start = [], None
    for g in range(h.dyn_base >> 4, (h.heap_limit >> 4) + 1):
        free = g < h.heap_limit >> 4 and g not in live
        if free and start is None:
            start = g
        elif not free and start is not None:
            if (g - start) * 16 >= 64:
                runs.append((start << 4, (g - start) << 4))
            start = None
    for i, (b, sz) in enumerate(runs):
        nxt = runs[i + 1][0] if i + 1 < len(runs) else 0
        words[b] = (GC_FREE_MAGIC << 96) | (sz << 64) | (nxt << 32)
    m = dict(dyn_base=h.dyn_base, heap_limit=h.heap_limit, spill_sp=h.spill_sp,
             exc_sp=h.exc_sp, frame_depth=h.frame_depth, run_head=runs[0][0] if runs else 0)
    m.update(meta)
    return gc_model.Dump(m, list(h.reg_roots), gc_model.Memory(words))


def minor_dump(c: GenCase, rem_nodes: list[gc_heapgen.Node], old: bytearray | None = None) -> gc_model.Dump:
    d = make_dump(c.h, c.minor_live(rem_nodes), gen=1, minor=1, barrier_idle=1)
    d.oldbm = gc_model.granules_bitmap(old if old is not None else c.old)
    d.remset = c.remset(rem_nodes)
    d.meta["remset_n"] = len(d.remset)
    return d


class TestGcModelMinor(unittest.TestCase):
    def test_trace_minor_matches_python(self) -> None:
        # trace_minor against a Python walk of the object graph, on random
        # old sets and remembered sets (complete or not).
        replaced = forced = 0
        for seed in range(GEN_SEEDS):
            c = GenCase(seed)
            res = gc_model.trace_minor(c.mem(), c.h.reg_roots, c.old, c.remset(c.rem_nodes), **c.kw())
            got = set(gc_model._ones(res.marked))
            want = c.minor_live(c.rem_nodes)
            if got != want:
                self.fail(f"seed {seed}: trace_minor retained {[hex(g << 4) for g in sorted(got - want)[:5]]} "
                          f"missed {[hex(g << 4) for g in sorted(want - got)[:5]]}")
            self.assertEqual((res.wild, res.bad_kind, res.reserved), (0, 0, 0), f"seed {seed}")
            replaced += bool(c.replaced)
            forced += bool(c.rem_nodes)
        self.assertGreater(replaced, GEN_SEEDS // 4)
        self.assertGreater(forced, GEN_SEEDS // 2)

    def test_barrier_gaps_match_python_and_complete_barrier_is_safe(self) -> None:
        gappy = 0
        for seed in range(GEN_SEEDS):
            c = GenCase(seed)
            edges: list[tuple[int, int]] = []
            full = gc_model.trace(c.mem(), c.h.reg_roots, edges=edges, **c.kw())
            got = {o for o, _ in gc_model.barrier_gaps(edges, full.marked, c.old, [], c.h.dyn_base)}
            want = {header(n) for n in c.gap_nodes}
            self.assertEqual(got, want, f"seed {seed}: gap owners")
            # Logging every gap owner (plus some others) makes the minor safe.
            rem = list({id(n): n for n in c.gap_nodes + c.rem_nodes}.values())
            res = gc_model.trace_minor(c.mem(), c.h.reg_roots, c.old, c.remset(rem), **c.kw())
            lost = [g for g in gc_model._ones(full.marked)
                    if g >= c.h.dyn_base >> 4 and not res.marked[g]]
            self.assertEqual(lost, [], f"seed {seed}: complete barrier lost {len(lost)} granules")
            self.assertEqual(gc_model.barrier_gaps(edges, full.marked, c.old, c.remset(rem), c.h.dyn_base), [])
            gappy += bool(want)
        self.assertGreater(gappy, GEN_SEEDS // 2)

    def test_check_dump_minor(self) -> None:
        caught = 0
        for seed in range(min(GEN_SEEDS, 60)):
            c = GenCase(seed)
            rem = list({id(n): n for n in c.gap_nodes + c.rem_nodes}.values())
            self.assertEqual(gc_model.check_dump(minor_dump(c, rem)), [], f"seed {seed}")
            if not c.gap_nodes:
                continue
            # Drop one gap owner: the barrier rule names it whether or not the
            # engine (here the dump's run list) went on to free anything.
            drop = c.gap_nodes[0]
            short = [n for n in rem if n is not drop]
            probs = gc_model.check_dump(minor_dump(c, short))
            self.assertTrue(any(p.startswith("BARRIER") for p in probs), f"seed {seed}: {probs}")
            caught += 1
        self.assertGreater(caught, 10)

    def test_minor_dump_faults_are_reported(self) -> None:
        c = next(c for c in map(GenCase, range(50))
                 if c.gap_nodes and any(not c.is_old(n) and n.allocs for n in c.h.nodes))
        rem = list({id(n): n for n in c.gap_nodes + c.rem_nodes}.values())
        good = minor_dump(c, rem)
        self.assertEqual(gc_model.check_dump(good), [])

        def probs(**change) -> list[str]:
            d = minor_dump(c, rem)
            d.meta.update(change)
            return gc_model.check_dump(d)

        self.assertTrue(any("barrier_idle" in p for p in probs(barrier_idle=0)))
        self.assertTrue(any("force_major" in p for p in probs(force_major=1)))
        self.assertTrue(any("remset_n" in p for p in probs(remset_n=len(rem) + 1)))
        # A remset entry naming a young owner.
        young = next(n for n in c.h.nodes if not c.is_old(n) and entry(n) and n.allocs)
        d = minor_dump(c, rem)
        d.remset.append(entry(young))
        d.meta["remset_n"] += 1
        self.assertTrue(any("non-old owner" in p for p in gc_model.check_dump(d)))
        # Freeing an old granule: a run list that also frees an old object
        # (live in the full trace or not) is a SAFETY failure.
        victim = next(n for n in c.h.nodes if c.is_old(n) and n.allocs[0][0] >= c.h.dyn_base
                      and n.allocs[0][1] >= 64)
        live = c.minor_live(rem)
        a, ln = victim.allocs[0]
        d = make_dump(c.h, live - set(range(a >> 4, (a + ln) >> 4)), gen=1, minor=1)
        d.oldbm, d.remset = gc_model.granules_bitmap(c.old), c.remset(rem)
        self.assertTrue(any("old granules" in p for p in gc_model.check_dump(d)))
        # A kept run over an old granule.
        self.assertTrue(any("kept run" in p for p in probs(keep_lo=a, keep_hi=a + ln)))
        # old_hi below an old bit.
        self.assertTrue(any("old_hi" in p for p in probs(old_hi=a)))

    def test_sequence_rules(self) -> None:
        checked = 0
        for seed in range(30):
            h = gc_heapgen.generate(seed)
            major = make_dump(h, h.expected_live(), gen=1, minor=0, barrier_idle=1)
            post = gc_model._check(major)[1]
            self.assertIsNotNone(post)
            # The next minor starts from exactly what the major left.
            c = GenCase(seed, h)
            c.old = bytearray(post)
            nxt = minor_dump(c, [])
            res = gc_model.check_sequence([major, nxt])
            self.assertEqual([p for _, ps in res for p in ps], [], f"seed {seed}")
            # A bit the major did not leave, or one it left that is gone.
            for flip in (h.heap_limit - 16, next(gc_model._ones(post))):
                bad = bytearray(post)
                bad[flip >> 4 if flip >= 16 else flip] ^= 1
                d = minor_dump(c, [], old=bad)
                ps = [p for _, ps in gc_model.check_sequence([major, d]) for p in ps]
                self.assertTrue(any(p.startswith("SEQUENCE") for p in ps), f"seed {seed}: {ps}")
            # A release between them clears its range. Only dead memory is
            # released; here, an object only roots reference (the minor
            # retraces it from them), so no old owner is left pointing in.
            held = {id(k) for n in h.nodes for k in n.children}
            dyn = [n for n in h.nodes if n.allocs and n.allocs[0][0] >= h.dyn_base
                   and post[n.allocs[0][0] >> 4] and id(n) not in held]
            if dyn:
                lo, ln = dyn[-1].allocs[0]
                hi = lo + ((ln + 15) & ~15)
                rel = bytearray(post)
                rel[lo >> 4:hi >> 4] = bytes((hi >> 4) - (lo >> 4))
                c.old = rel
                d = minor_dump(c, [])
                d.events = [("release", lo, hi)]
                self.assertEqual([p for _, ps in gc_model.check_sequence([major, d]) for p in ps], [],
                                 f"seed {seed}: release")
                c.old = bytearray(post)
                d = minor_dump(c, [])
                d.events = [("release", lo, hi)]
                ps = [p for _, ps in gc_model.check_sequence([major, d]) for p in ps]
                self.assertTrue(any(p.startswith("SEQUENCE") for p in ps), f"seed {seed}: uncleared")
                checked += 1
            # After an abandon (or enable, reset) the next collection is a major.
            for ev in ("abandon", "enable", "reset"):
                d = minor_dump(c, [])
                d.events = [(ev, 0, 0)]
                ps = [p for _, ps in gc_model.check_sequence([major, d]) for p in ps]
                self.assertTrue(any("must be a major" in p for p in ps), ev)
                m2 = make_dump(h, h.expected_live(), gen=1, minor=0, barrier_idle=1)
                m2.events = [(ev, 0, 0)]
                self.assertEqual([p for _, ps in gc_model.check_sequence([major, m2]) for p in ps], [])
        self.assertGreater(checked, 5)
        print(f"G2 gen seeds={GEN_SEEDS} sequence_seeds=30 release_cases={checked}")


if __name__ == "__main__":
    unittest.main()
