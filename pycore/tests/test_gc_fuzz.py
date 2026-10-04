"""G8 generator: every program lints and runs on host CPython (planning/gc_plan.md §10.2).

The simulator runs live in `make pycore-gc-fuzz`; this only guards the
generator, so a lint rejection or a host-side exception never reaches the
gate as a false failure.
"""

from __future__ import annotations

import os
import pathlib
import tempfile
import unittest

from pycore.tools import gc_fuzz, pycore_cli, run_image_test

SEEDS = int(os.environ.get("GC_FUZZ_GEN_SEEDS", "40"))


class GcFuzzGenerator(unittest.TestCase):
    def check(self, growth: bool) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for seed in range(SEEDS):
                src = pathlib.Path(tmp) / f"img_gc_fuzz_{seed}.py"
                src.write_text(gc_fuzz.generate(seed, growth), encoding="utf-8")
                problems = pycore_cli.lint_path(src, entry="managed_entry")
                self.assertEqual(list(problems), [], f"seed {seed} growth={growth}")
                result = run_image_test.host_entry_result(src, "managed_entry")
                self.assertIsInstance(result, int, f"seed {seed} growth={growth}")

    def test_single_core_programs(self) -> None:
        self.check(growth=False)

    def test_two_core_programs(self) -> None:
        self.check(growth=True)

    def test_deterministic(self) -> None:
        self.assertEqual(gc_fuzz.generate(7, False), gc_fuzz.generate(7, False))
        self.assertNotEqual(gc_fuzz.generate(7, False), gc_fuzz.generate(8, False))

    def test_list_to_tuple_uses_starred_display(self) -> None:
        src = gc_fuzz.generate(0, False)
        self.assertIn("(*_r,)", src)

    def test_bulk_and_exception_coverage_prelude(self) -> None:
        src = gc_fuzz.generate(0, False)
        self.assertIn("{*_cov_st}", src)
        self.assertIn("{**_cov_da, **_cov_db}", src)
        self.assertIn("_kwmerge(**", src)
        # Non-compile seeds keep a live exception from the start (OBK6).
        # Compile seeds raise only at the end (CELL/FUNCTION + live exc
        # is B11).
        self.assertIn("compile=False", src)
        self.assertIn("_keep_ex = ex", src)
        self.assertLess(src.index("_keep_ex = ex"), src.index("L0 = ["))
        src_c = gc_fuzz.generate(2, False)
        self.assertIn("compile=True", src_c)
        self.assertNotIn("_keep_ex = ex", src_c)
        self.assertIn('raise ValueError("exc-end-payload-long")', src_c)

    def test_no_len_on_tuple_mode_range(self) -> None:
        # BI_LEN TYPE-traps tuple-mode RANGE (stop outside signed 32-bit).
        for seed in range(SEEDS):
            src = gc_fuzz.generate(seed, False)
            self.assertNotIn("len(R0)", src, f"seed {seed}")
            self.assertNotIn("len(range(0, 1099511627776", src, f"seed {seed}")


if __name__ == "__main__":
    unittest.main()
