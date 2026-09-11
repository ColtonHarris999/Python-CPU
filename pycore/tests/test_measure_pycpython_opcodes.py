"""Classification of the vendored PyCPython opcode mix vs PyCore."""

from __future__ import annotations

import sys
import unittest
from collections import Counter

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("PyCPython opcode measurement requires Python 3.14")

from pathlib import Path

_VENDOR_COMPILE = (
    Path(__file__).resolve().parents[2]
    / "vendor"
    / "pycpython"
    / "pycpython"
    / "compile.py"
)
if not _VENDOR_COMPILE.is_file():
    raise unittest.SkipTest(
        "PyCPython submodule not initialized (git submodule update --init)"
    )

from measure_pycpython_opcodes import classify_opcode, collect_mix


class TestClassifyOpcode(unittest.TestCase):
    def test_extended_arg_is_full(self):
        self.assertEqual(classify_opcode("EXTENDED_ARG", Counter({1: 3}), {}), "full")

    def test_unlisted_is_unsupported(self):
        self.assertEqual(classify_opcode("LOAD_BUILD_CLASS", Counter({0: 1}), {}), "unsupported")

    def test_execute_with_all_allowed_opargs_is_full(self):
        isa = {"opcodes": {"RERAISE": {"support": "execute", "supported_opargs": [0, 1]}}}
        self.assertEqual(classify_opcode("RERAISE", Counter({0: 10, 1: 20}), isa), "full")

    def test_execute_with_disallowed_oparg_is_partial(self):
        isa = {
            "opcodes": {
                "CALL_INTRINSIC_1": {"support": "execute", "supported_opargs": [6]}
            }
        }
        self.assertEqual(
            classify_opcode("CALL_INTRINSIC_1", Counter({6: 10, 2: 3}), isa),
            "partial",
        )

    def test_json_partial_stays_partial(self):
        isa = {"opcodes": {"CALL": {"support": "partial"}}}
        self.assertEqual(classify_opcode("CALL", Counter({2: 5}), isa), "partial")

    def test_trap_is_unsupported(self):
        isa = {"opcodes": {"LOAD_COMMON_CONSTANT": {"support": "trap"}}}
        self.assertEqual(
            classify_opcode("LOAD_COMMON_CONSTANT", Counter({0: 4}), isa),
            "unsupported",
        )


class TestPyCPythonMix(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = collect_mix()

    def test_package_shape(self):
        self.assertEqual(len(self.report.files), 20)
        self.assertGreater(self.report.n_codes, 1000)
        self.assertGreater(self.report.logical_units, 100000)
        self.assertGreater(self.report.raw_units, self.report.logical_units)
        self.assertGreater(self.report.cache_units, 0)

    def test_reraise_is_partial_because_of_oparg_2(self):
        st = self.report.stats["RERAISE"]
        self.assertEqual(st.json_support, "execute")
        self.assertEqual(st.bucket, "partial")
        self.assertEqual(st.args[2], 1)
        self.assertGreater(st.args[0] + st.args[1], 100)

    def test_call_is_partial(self):
        self.assertEqual(self.report.stats["CALL"].bucket, "partial")
        self.assertEqual(self.report.stats["MAKE_FUNCTION"].bucket, "partial")
        self.assertEqual(self.report.stats["CALL_INTRINSIC_1"].bucket, "partial")

    def test_high_impact_unsupported(self):
        un = set(self.report.buckets["unsupported"])
        for name in (
            "LOAD_BUILD_CLASS",
            "LOAD_COMMON_CONSTANT",
            "IMPORT_NAME",
            "IMPORT_FROM",
            "LOAD_LOCALS",
            "MAKE_CELL",
            "LOAD_DEREF",
            "YIELD_VALUE",
            "JUMP_BACKWARD_NO_INTERRUPT",
        ):
            self.assertIn(name, un, name)

    def test_three_buckets_cover_every_opcode(self):
        classified = (
            set(self.report.buckets["full"])
            | set(self.report.buckets["partial"])
            | set(self.report.buckets["unsupported"])
        )
        self.assertEqual(classified, set(self.report.stats))


if __name__ == "__main__":
    unittest.main()
