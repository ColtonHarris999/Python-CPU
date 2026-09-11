"""Unit tests for encoding.allocator_list_capacity."""

from __future__ import annotations

import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("requires Python 3.14")

from encoding import (
    ALLOCATOR_LIST_CAPACITY_MAX,
    ALLOCATOR_LIST_CAPACITY_MIN,
    HEAP_LIMIT,
    LIST_ELEMENT_BYTES,
    allocator_list_capacity,
)
from run_image_test import apply_heap_list_capacity_inject


class TestAllocatorListCapacity(unittest.TestCase):
    def test_multiple_of_sixteen(self) -> None:
        for avail in (0, 100, 1024, 16_384, 64_000, HEAP_LIMIT):
            cap = allocator_list_capacity(avail)
            self.assertEqual(cap % 16, 0, avail)

    def test_zero_budget_is_zero(self) -> None:
        self.assertEqual(allocator_list_capacity(0), 0)
        self.assertEqual(allocator_list_capacity(-1), 0)
        self.assertEqual(allocator_list_capacity(LIST_ELEMENT_BYTES), 0)
        self.assertEqual(ALLOCATOR_LIST_CAPACITY_MIN % 16, 0)
        self.assertGreaterEqual(ALLOCATOR_LIST_CAPACITY_MIN, 48)

    def test_never_exceeds_grow_budget(self) -> None:
        slack = LIST_ELEMENT_BYTES * 4
        for avail in (0, 100, 7200, 16_384, 64_000, HEAP_LIMIT):
            cap = allocator_list_capacity(avail)
            self.assertLessEqual(cap * slack, max(avail, 0), avail)

    def test_shrinks_when_budget_shrinks(self) -> None:
        large = allocator_list_capacity(200_000)
        small = allocator_list_capacity(20_000)
        self.assertGreater(large, small)
        self.assertGreaterEqual(small, ALLOCATOR_LIST_CAPACITY_MIN)

    def test_clamped_to_max(self) -> None:
        self.assertEqual(
            allocator_list_capacity(10**9),
            ALLOCATOR_LIST_CAPACITY_MAX,
        )

    def test_live_firmware_image_meets_min(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        path = root / "allocator_list.py"
        text = apply_heap_list_capacity_inject(
            path.read_text(encoding="utf-8"), filename=path.name
        )
        capacity = None
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("CAPACITY ="):
                capacity = int(stripped.split("=", 1)[1].split("#")[0])
                break
        self.assertIsNotNone(capacity)
        self.assertGreaterEqual(capacity, ALLOCATOR_LIST_CAPACITY_MIN)
        ns: dict[str, object] = {}
        exec(compile(text, path.name, "exec"), ns)
        result = ns["managed_entry"]()
        self.assertIsInstance(result, int)
        self.assertGreaterEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
