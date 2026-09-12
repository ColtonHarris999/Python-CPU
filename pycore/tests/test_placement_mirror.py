"""RTL pycore_*_place_* helpers must match HeapImageBuilder bump allocation.

The P0 memory-map mirror only covers scalar constants. P1's selective
line-alignment (≥64 B) lives in both pycore_heap_place and
HeapImageBuilder._alloc; a drift there silently breaks BUILD_MAP /
BUILD_LIST / BUILD_SET / BUILD_TUPLE. This ports the RTL helpers to Python
and compares them against real HeapImageBuilder allocations.
"""

from __future__ import annotations

import unittest

from pycore.tools import encoding
from pycore.tools.heap_image import HeapImageBuilder

LINE = encoding.LINE_BYTES
START_PHASES = (0, 16, 32, 48)
SLOT_COUNTS = (4, 8, 16, 32, 64, 128)


def rtl_align_line(addr: int) -> int:
    return (addr + LINE - 1) & ~(LINE - 1)


def rtl_heap_place(ptr: int, nbytes: int) -> int:
    return rtl_align_line(ptr) if nbytes >= LINE else ptr


def rtl_dict_place_obj(ptr: int) -> int:
    return rtl_heap_place(ptr, 48)


def rtl_dict_place_order(ptr: int) -> int:
    # nbytes=128 matches pycore_dict_place_order (min live order 4*32).
    return rtl_heap_place(rtl_dict_place_obj(ptr) + 48, 128)


def rtl_dict_place_table(ptr: int, slot_count: int) -> int:
    if slot_count == 0:
        return 0
    return rtl_heap_place(
        rtl_dict_place_order(ptr) + (slot_count << 5), slot_count << 6
    )


def rtl_dict_place_end(ptr: int, slot_count: int) -> int:
    if slot_count == 0:
        return rtl_dict_place_obj(ptr) + 48
    return rtl_dict_place_table(ptr, slot_count) + (slot_count << 6)


def rtl_dict_alloc_bytes(slot_count: int) -> int:
    return rtl_dict_place_end(0, slot_count)


def rtl_set_place_obj(ptr: int) -> int:
    return rtl_heap_place(ptr, 32)


def rtl_set_place_table(ptr: int, slot_count: int) -> int:
    if slot_count == 0:
        return 0
    return rtl_heap_place(rtl_set_place_obj(ptr) + 32, slot_count << 5)


def rtl_set_place_end(ptr: int, slot_count: int) -> int:
    if slot_count == 0:
        return rtl_set_place_obj(ptr) + 32
    return rtl_set_place_table(ptr, slot_count) + (slot_count << 5)


def rtl_list_place_obj(ptr: int) -> int:
    return rtl_heap_place(ptr, 32)


def rtl_list_place_buf(ptr: int, capacity: int) -> int:
    if capacity == 0:
        return 0
    return rtl_heap_place(rtl_list_place_obj(ptr) + 32, capacity << 5)


def rtl_list_place_end(ptr: int, capacity: int) -> int:
    if capacity == 0:
        return rtl_list_place_obj(ptr) + 32
    return rtl_list_place_buf(ptr, capacity) + (capacity << 5)


def rtl_tuple_place(ptr: int, size: int) -> tuple[int, int]:
    nbytes = size << 5
    base = rtl_heap_place(ptr, nbytes)
    return base, base + nbytes


def _int_entry(n: int) -> tuple[int, int]:
    return encoding.TAG_INT, encoding.int_value(n)


class TestPlacementMirror(unittest.TestCase):
    def test_dict_matches_heap_image_builder(self) -> None:
        for phase in START_PHASES:
            for n in SLOT_COUNTS:
                start = encoding.HEAP_BASE + phase
                heap = HeapImageBuilder(base=start)
                tag, value = heap.alloc_dict([], slot_count=n)
                obj = encoding.mut_addr(value)
                ptr_word = heap.words[obj + 32]
                table = ptr_word & ((1 << 64) - 1)
                order = ptr_word >> 64
                self.assertEqual(obj, rtl_dict_place_obj(start), (phase, n, "obj"))
                self.assertEqual(order, rtl_dict_place_order(start), (phase, n, "order"))
                self.assertEqual(table, rtl_dict_place_table(start, n), (phase, n, "table"))
                self.assertEqual(heap.end_ptr, rtl_dict_place_end(start, n), (phase, n, "end"))

    def test_set_matches_heap_image_builder(self) -> None:
        for phase in START_PHASES:
            for n in SLOT_COUNTS:
                start = encoding.HEAP_BASE + phase
                heap = HeapImageBuilder(base=start)
                tag, value = heap.alloc_set([], slot_count=n)
                obj = encoding.mut_addr(value)
                table = heap.words[obj + 16] & ((1 << 64) - 1)
                self.assertEqual(obj, rtl_set_place_obj(start), (phase, n, "obj"))
                self.assertEqual(table, rtl_set_place_table(start, n), (phase, n, "table"))
                self.assertEqual(heap.end_ptr, rtl_set_place_end(start, n), (phase, n, "end"))

    def test_list_matches_heap_image_builder(self) -> None:
        for phase in START_PHASES:
            for n in SLOT_COUNTS:
                start = encoding.HEAP_BASE + phase
                heap = HeapImageBuilder(base=start)
                tag, value = heap.alloc_list_with_capacity([], n)
                obj = encoding.mut_addr(value)
                buf = heap.words[obj + 16] & ((1 << 64) - 1)
                self.assertEqual(obj, rtl_list_place_obj(start), (phase, n, "obj"))
                self.assertEqual(buf, rtl_list_place_buf(start, n), (phase, n, "buf"))
                self.assertEqual(heap.end_ptr, rtl_list_place_end(start, n), (phase, n, "end"))

    def test_tuple_matches_heap_image_builder(self) -> None:
        for phase in START_PHASES:
            for n in SLOT_COUNTS:
                start = encoding.HEAP_BASE + phase
                heap = HeapImageBuilder(base=start)
                elements = [_int_entry(i) for i in range(n)]
                tag, value = heap.alloc_tuple(elements)
                base = value & ((1 << 64) - 1)
                rtl_base, rtl_end = rtl_tuple_place(start, n)
                self.assertEqual(base, rtl_base, (phase, n, "base"))
                self.assertEqual(heap.end_ptr, rtl_end, (phase, n, "end"))

    def test_dict_alloc_bytes_is_place_end_from_zero(self) -> None:
        for n in SLOT_COUNTS:
            heap = HeapImageBuilder(base=0)
            heap.alloc_dict([], slot_count=n)
            self.assertEqual(rtl_dict_alloc_bytes(n), heap.end_ptr, n)
            self.assertEqual(rtl_dict_alloc_bytes(n), rtl_dict_place_end(0, n), n)


if __name__ == "__main__":
    unittest.main()
