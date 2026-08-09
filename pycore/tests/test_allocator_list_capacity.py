"""Unit tests for encoding.allocator_list_capacity."""

from __future__ import annotations

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


class TestAllocatorListCapacity(unittest.TestCase):
    def test_multiple_of_sixteen(self) -> None:
        for avail in (0, 100, 1024, 16_384, 64_000, HEAP_LIMIT):
            cap = allocator_list_capacity(avail)
            self.assertEqual(cap % 16, 0, avail)

    def test_never_below_minimum(self) -> None:
        self.assertEqual(allocator_list_capacity(0), ALLOCATOR_LIST_CAPACITY_MIN)
        self.assertEqual(allocator_list_capacity(-1), ALLOCATOR_LIST_CAPACITY_MIN)
        self.assertEqual(
            allocator_list_capacity(LIST_ELEMENT_BYTES),
            ALLOCATOR_LIST_CAPACITY_MIN,
        )
        self.assertEqual(ALLOCATOR_LIST_CAPACITY_MIN % 16, 0)
        self.assertGreaterEqual(ALLOCATOR_LIST_CAPACITY_MIN, 128)

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


if __name__ == "__main__":
    unittest.main()
