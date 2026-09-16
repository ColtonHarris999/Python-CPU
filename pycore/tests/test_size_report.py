"""Host tests for W-8 / A8 size report (compiler_design.md step K)."""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("size report tests require Python 3.14")

from encoding import CODE_RAM_SLOT_BASE, CODE_RAM_SLOTS, HEAP_BASE, HEAP_LIMIT
from size_report import Region, collect_size_report, format_report, main


class TestSizeReport(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = collect_size_report()

    def test_regions_fit_hardware_ceilings(self) -> None:
        self.assertTrue(self.report.ok)
        self.assertEqual(len(self.report.regions), 3)
        rom, ram, heap = self.report.regions
        self.assertEqual(rom.capacity, CODE_RAM_SLOT_BASE)
        self.assertEqual(ram.capacity, CODE_RAM_SLOTS)
        self.assertEqual(heap.capacity, HEAP_LIMIT - HEAP_BASE)
        self.assertGreater(rom.used, 0)
        self.assertGreater(ram.used, 0)
        self.assertGreater(heap.used, 0)
        self.assertLessEqual(rom.used, rom.capacity)
        self.assertLessEqual(ram.used, ram.capacity)
        self.assertLessEqual(heap.used, heap.capacity)

    def test_compiler_lives_in_code_ram_not_rom(self) -> None:
        rom, ram, _heap = self.report.regions
        self.assertGreater(ram.used, rom.used)
        self.assertLess(ram.remaining, ram.capacity)

    def test_format_mentions_overflow_gate(self) -> None:
        text = format_report(self.report)
        self.assertIn("PyCore size report", text)
        self.assertIn("Code RAM (compiler)", text)
        self.assertNotIn("OVERFLOW", text)
        self.assertIn("compiled-output headroom", text)

    def test_overflow_region_is_not_ok(self) -> None:
        region = Region("toy", 5, 4, "slots")
        self.assertFalse(region.ok)
        self.assertEqual(region.remaining, -1)

    def test_main_returns_zero_when_within_budget(self) -> None:
        self.assertEqual(main([]), 0)


if __name__ == "__main__":
    unittest.main()
