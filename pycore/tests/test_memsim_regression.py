"""The memsim harness must keep producing the numbers the plan is sized from.

`pycore/tools/memsim/` is what `memory_hierarchy_report.md` rests on and what
P9 re-runs to check measured-vs-predicted. It imports the production image
builder (`heap_image`, `image_from_source`, `pycore_cli`), so a change to any
of those can silently break it — and nothing else in the suite exercises it.

These are invariant checks, not golden numbers: they pin the per-opcode dmem
access counts that the RTL actually issues, so the model cannot drift away
from the hardware without failing here.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MEMSIM = REPO_ROOT / "pycore" / "tools" / "memsim"
if str(MEMSIM) not in sys.path:
    sys.path.insert(0, str(MEMSIM))


class TestMemsimRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        from run import run_program  # noqa: PLC0415

        cls.result = run_program(MEMSIM / "bench" / "bench_fib.py")

    def test_trace_is_non_trivial(self) -> None:
        """A silently-empty trace would make every downstream number zero."""
        self.assertGreater(self.result["dynamic_ops"], 10_000)
        self.assertGreater(self.result["dmem_accesses"], 10_000)
        self.assertGreater(self.result["imem_slots"], self.result["dynamic_ops"])

    def test_per_opcode_dmem_counts_match_the_rtl(self) -> None:
        """These counts are read off the as-built container/CALL FSMs.

        LOAD_GLOBAL: co_names val+tag, dict header, table_ptr, probe ktag,
        probe kval, vval, vtag = 8.
        CALL: entry_slot, co_consts, co_names, metadata, co_defaults, plus two
        frame-descriptor pushes = 7.
        RETURN_VALUE: two frame pops plus the caller's co_consts and co_names = 4.
        LOAD_CONST: co_consts val+tag = 2.
        """
        expected = {
            "LOAD_GLOBAL": 8,
            "CALL": 7,
            "RETURN_VALUE": 4,
            "LOAD_CONST": 2,
        }
        seen: dict[str, set[int]] = {}
        for cost in self.result["_costs"]:
            if cost.opname in expected:
                seen.setdefault(cost.opname, set()).add(len(cost.accesses))

        for opname, want in expected.items():
            self.assertIn(opname, seen, f"{opname} never executed in bench_fib")
            counts = seen[opname] - {0}  # 0 = builtin dispatch, no frame entry
            self.assertEqual(
                counts,
                {want},
                f"{opname} should issue {want} dmem accesses, saw {sorted(counts)}",
            )

    def test_scalar_opcodes_issue_no_dmem(self) -> None:
        """The ALU fast path must stay off the memory port."""
        for cost in self.result["_costs"]:
            if cost.opname in ("LOAD_FAST_BORROW", "LOAD_SMALL_INT",
                               "COMPARE_OP", "POP_JUMP_IF_FALSE"):
                self.assertEqual(
                    cost.accesses, [],
                    f"{cost.opname} must not touch dmem")

    def test_addresses_land_in_the_real_heap(self) -> None:
        """Model addresses come from a real built image, not a synthetic map."""
        from pycore.tools.encoding import HEAP_BASE, HEAP_LIMIT, FRAME_STACK_BASE  # noqa: PLC0415

        frame_base = FRAME_STACK_BASE
        for cost in self.result["_costs"]:
            for acc in cost.accesses:
                if acc.cls == "frame":
                    self.assertGreaterEqual(acc.addr, frame_base)
                else:
                    self.assertGreaterEqual(acc.addr, HEAP_BASE)
                    self.assertLess(acc.addr, HEAP_LIMIT)

    def test_line_alignment_survives(self) -> None:
        """P1 start-aligns allocations of a line or more (report F3b).

        If `_alloc` loses its alignment, the L1D sizing in the plan no longer
        holds. Dict tables are the case that matters: a 64-byte slot must not
        straddle two lines.
        """
        import layout as L  # noqa: PLC0415
        from pycore.tools.encoding import LINE_BYTES  # noqa: PLC0415

        lay = self.result["_lay"]
        self.assertEqual(lay.globals_table % LINE_BYTES, 0,
                         "globals dict table must start on a cache line")
        self.assertEqual(lay.builtins_table % LINE_BYTES, 0,
                         "builtins dict table must start on a cache line")
        self.assertTrue(callable(L.set_heap_alignment))

    def test_gic_index_matches_rtl_namei_lsbs(self) -> None:
        """GIC set index is namei[2:0], not Python's salted hash()."""
        from cachesim import DirectTagCache, gic_set_index  # noqa: PLC0415

        self.assertEqual(gic_set_index(("code", 0)), 0)
        self.assertEqual(gic_set_index(("code", 7)), 7)
        self.assertEqual(gic_set_index(("code", 8)), 0)
        gc = DirectTagCache(16, 2, index_fn=gic_set_index)
        gc.access(("c", 1))
        gc.access(("c", 1))
        self.assertEqual(gc.hits, 1)
        self.assertEqual(gc.misses, 1)

    def test_string_bench_emits_stracc_accesses(self) -> None:
        """Long-string concat/index/find must show up as C_STR, not disappear."""
        from run import run_program  # noqa: PLC0415
        import model as M  # noqa: PLC0415

        r = run_program(MEMSIM / "bench" / "bench_strings.py")
        n_str = sum(1 for c in r["_costs"] for a in c.accesses if a.cls == M.C_STR)
        self.assertGreater(n_str, 20, "bench_strings should issue STRACC dmem")
        for c in r["_costs"]:
            for acc in c.accesses:
                if acc.cls == M.C_STR:
                    self.assertGreaterEqual(acc.addr, 0x440)

    def test_str_access_class_exists(self) -> None:
        """P9 models STRACC payload traffic as its own class."""
        import model as M  # noqa: PLC0415

        self.assertEqual(M.C_STR, "str")
        self.assertTrue(any(a.cls != M.C_STR for c in self.result["_costs"]
                            for a in c.accesses))

    def test_rtl_counter_parser_round_trip(self) -> None:
        """tb_container lines must parse without depending on Verilator."""
        from rtl_measure import parse_counters  # noqa: PLC0415

        sample = (
            "PASS: img_recursion.hex — tag=1 value=0x37 cycles=23675\n"
            "L1I hits=878 misses=10  L1D hits=1557 misses=25 wb=3 "
            "frame_hits=1414 frame_misses=6\n"
            "CODC hits=353 misses=2 fills=2 flushes=1\n"
            "GIC hits=175 misses=178 fills=178 flushes=3\n"
            "fetch mem_req=100 buf_hit=50\n"
        )
        c = parse_counters(sample)
        self.assertTrue(c.passed)
        self.assertEqual(c.cycles, 23675)
        self.assertEqual(c.l1i_hits, 878)
        self.assertEqual(c.l1d_misses, 25)
        self.assertEqual(c.frame_hits, 1414)
        self.assertAlmostEqual(c.frame_hit_rate, 1414 / 1420)
        self.assertEqual(c.codc_fills, 2)
        self.assertEqual(c.gic_hits, 175)
        self.assertEqual(c.fetch_buf_hit, 50)


if __name__ == "__main__":
    unittest.main()
