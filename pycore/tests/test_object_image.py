"""M1 object-substrate tests: OBK_* layouts via HeapImageBuilder."""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("object-image tests require Python 3.14")

from encoding import (
    OBK_BOUND_METHOD,
    OBK_BUILTIN,
    OBK_BYTEARRAY,
    OBK_EXCEPTION,
    OBK_INSTANCE,
    OBK_TYPE,
    OBJ_BOUND_METHOD_BYTES,
    OBJ_BUILTIN_BYTES,
    OBJ_BYTEARRAY_BYTES,
    OBJ_EXCEPTION_BYTES,
    OBJ_INSTANCE_BYTES,
    OBJ_TYPE_BYTES,
    TAG_CODE_OBJECT,
    TAG_DICT,
    TAG_INT,
    TAG_NONE,
    TAG_NULL,
    TAG_OBJECT,
    TAG_SHORT_STR,
    TAG_TUPLE,
    encode_short_str,
    int_value,
    ob_flags,
    ob_kind,
    ob_type,
    obj_field_tag_addr,
    obj_field_val_addr,
    pack_ob_head,
)
from heap_image import HeapImageBuilder


class TestObHeadPacking(unittest.TestCase):
    def test_pack_round_trip(self) -> None:
        head = pack_ob_head(OBK_TYPE, 0xA5A5A5A5, 0x1234)
        self.assertEqual(ob_kind(head), OBK_TYPE)
        self.assertEqual(ob_flags(head), 0xA5A5A5A5)
        self.assertEqual(ob_type(head), 0x1234)

    def test_field_addrs_skip_header(self) -> None:
        obj = 0x400
        self.assertEqual(obj_field_val_addr(obj, 0), 0x420)
        self.assertEqual(obj_field_tag_addr(obj, 0), 0x430)
        self.assertEqual(obj_field_val_addr(obj, 1), 0x440)


class TestAllocInstance(unittest.TestCase):
    def test_layout_and_dict(self) -> None:
        heap = HeapImageBuilder()
        handle = heap.alloc_instance()
        self.assertEqual(handle[0], TAG_OBJECT)
        addr = handle[1]
        self.assertEqual(addr & 0xF, 0)
        self.assertEqual(heap.end_ptr - addr, OBJ_INSTANCE_BYTES)

        head = heap.words[addr]
        self.assertEqual(ob_kind(head), OBK_INSTANCE)
        self.assertEqual(ob_type(head), 0)
        self.assertEqual(heap.words[addr + 16] & 0xF, TAG_OBJECT)

        d_val = heap.words[obj_field_val_addr(addr, 0)]
        d_tag = heap.words[obj_field_tag_addr(addr, 0)] & 0xF
        self.assertEqual(d_tag, TAG_DICT)
        # Dict handle value is the object address (low 64).
        self.assertEqual(d_val & ((1 << 64) - 1), d_val)
        self.assertGreaterEqual(d_val & ((1 << 64) - 1), heap.base)

    def test_type_addr_recorded(self) -> None:
        heap = HeapImageBuilder()
        handle = heap.alloc_instance(type_addr=0xABC0)
        self.assertEqual(ob_type(heap.words[handle[1]]), 0xABC0)


class TestAllocType(unittest.TestCase):
    def test_layout(self) -> None:
        heap = HeapImageBuilder()
        name = (TAG_SHORT_STR, encode_short_str(b"C"))
        handle = heap.alloc_type(name)
        self.assertEqual(handle[0], TAG_OBJECT)
        addr = handle[1]
        self.assertEqual(heap.end_ptr - addr, OBJ_TYPE_BYTES)
        self.assertEqual(ob_kind(heap.words[addr]), OBK_TYPE)

        f0_tag = heap.words[obj_field_tag_addr(addr, 0)] & 0xF
        f1_tag = heap.words[obj_field_tag_addr(addr, 1)] & 0xF
        f2_tag = heap.words[obj_field_tag_addr(addr, 2)] & 0xF
        self.assertEqual(f0_tag, TAG_DICT)
        self.assertEqual(f1_tag, TAG_NONE)
        self.assertEqual(f2_tag, TAG_SHORT_STR)
        self.assertEqual(heap.words[obj_field_val_addr(addr, 2)], name[1])


class TestAllocBoundMethod(unittest.TestCase):
    def test_layout(self) -> None:
        heap = HeapImageBuilder()
        consts = heap.alloc_tuple([])
        names = heap.alloc_tuple([])
        code = heap.add_code_object(
            0, consts, names, stacksize=2, nlocals=1, argcount=1
        )
        inst = heap.alloc_instance()
        bm = heap.alloc_bound_method(code, inst)
        self.assertEqual(bm[0], TAG_OBJECT)
        addr = bm[1]
        self.assertEqual(heap.end_ptr - addr, OBJ_BOUND_METHOD_BYTES)
        self.assertEqual(ob_kind(heap.words[addr]), OBK_BOUND_METHOD)
        self.assertEqual(
            heap.words[obj_field_tag_addr(addr, 0)] & 0xF, TAG_CODE_OBJECT
        )
        self.assertEqual(
            heap.words[obj_field_tag_addr(addr, 1)] & 0xF, TAG_OBJECT
        )


class TestAllocBuiltin(unittest.TestCase):
    def test_free_and_bound(self) -> None:
        heap = HeapImageBuilder()
        free = heap.alloc_builtin(4)
        addr = free[1]
        self.assertEqual(ob_kind(heap.words[addr]), OBK_BUILTIN)
        self.assertEqual(heap.end_ptr - addr, OBJ_BUILTIN_BYTES)
        self.assertEqual(
            heap.words[obj_field_val_addr(addr, 0)], int_value(4)
        )
        self.assertEqual(
            heap.words[obj_field_tag_addr(addr, 1)] & 0xF, TAG_NULL
        )

        inst = heap.alloc_instance()
        bound = heap.alloc_builtin(5, inst)
        baddr = bound[1]
        self.assertEqual(
            heap.words[obj_field_tag_addr(baddr, 1)] & 0xF, TAG_OBJECT
        )


class TestAllocBytearray(unittest.TestCase):
    def test_zeroed_buffer(self) -> None:
        heap = HeapImageBuilder()
        handle = heap.alloc_bytearray(16)
        addr = handle[1]
        self.assertEqual(ob_kind(heap.words[addr]), OBK_BYTEARRAY)
        self.assertEqual(heap.words[obj_field_val_addr(addr, 0)], 16)
        buf = heap.words[obj_field_val_addr(addr, 1)]
        cap = heap.words[obj_field_val_addr(addr, 2)]
        self.assertEqual(cap, 16)
        self.assertNotEqual(buf, 0)
        self.assertEqual(buf & 0xF, 0)
        self.assertEqual(heap.words[buf], 0)


class TestAllocException(unittest.TestCase):
    def test_layout(self) -> None:
        heap = HeapImageBuilder()
        name = (TAG_SHORT_STR, encode_short_str(b"E"))
        etype = heap.alloc_type(name)
        args = heap.alloc_tuple([(TAG_INT, int_value(1))])
        exc = heap.alloc_exception(etype, args)
        addr = exc[1]
        self.assertEqual(ob_kind(heap.words[addr]), OBK_EXCEPTION)
        self.assertEqual(heap.end_ptr - addr, OBJ_EXCEPTION_BYTES)
        self.assertEqual(
            heap.words[obj_field_tag_addr(addr, 0)] & 0xF, TAG_OBJECT
        )
        self.assertEqual(
            heap.words[obj_field_tag_addr(addr, 1)] & 0xF, TAG_TUPLE
        )


class TestSizesAligned(unittest.TestCase):
    def test_all_kinds_16_aligned(self) -> None:
        for size in (
            OBJ_INSTANCE_BYTES,
            OBJ_TYPE_BYTES,
            OBJ_BOUND_METHOD_BYTES,
            OBJ_BUILTIN_BYTES,
            OBJ_BYTEARRAY_BYTES,
            OBJ_EXCEPTION_BYTES,
        ):
            self.assertEqual(size & 0xF, 0)


if __name__ == "__main__":
    unittest.main()
