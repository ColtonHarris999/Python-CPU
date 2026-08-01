"""Unit tests for container readiness: tag_constant, interning, BUILD_TUPLE, hash."""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("preprocess tests require Python 3.14")

from pycore.tools import encoding, heap_image, preprocess


def _compile_fn(src: str, name: str = "managed_entry"):
    ns: dict = {}
    exec(compile(src, "<test>", "exec"), ns)
    return ns[name]


class TestRestructuredTagMap(unittest.TestCase):
    def test_primary_tags_match_rtl_map(self) -> None:
        self.assertEqual(
            [
                encoding.TAG_CONTROL,
                encoding.TAG_INT,
                encoding.TAG_FLOAT,
                encoding.TAG_COMPLEX,
                encoding.TAG_BOOL,
                encoding.TAG_ITER,
                encoding.TAG_TUPLE,
                encoding.TAG_SHORT_STR,
                encoding.TAG_LONG_STR,
                encoding.TAG_MUT_COLLEC,
                encoding.TAG_OBJECT,
                encoding.TAG_RANGE,
                encoding.TAG_BYTES,
                encoding.TAG_CODE_OBJECT,
                encoding.TAG_TOMBSTONE,
                encoding.TAG_FROZENSET,
            ],
            list(range(16)),
        )

    def test_control_entries(self) -> None:
        self.assertEqual(encoding.make_uninit(), (encoding.TAG_CONTROL, 0))
        self.assertEqual(encoding.make_none(), (encoding.TAG_CONTROL, 1))
        self.assertEqual(encoding.make_null(), (encoding.TAG_CONTROL, 2))

    def test_mutable_handle_kind_and_address(self) -> None:
        tag, value = encoding.make_list(0x440)
        self.assertEqual(tag, encoding.TAG_MUT_COLLEC)
        self.assertEqual(encoding.mut_kind(value), encoding.MUT_LIST)
        self.assertEqual(encoding.mut_addr(value), 0x440)

    def test_complex_layout(self) -> None:
        tag, value = encoding.make_complex(1.5, -2.25)
        self.assertEqual(tag, encoding.TAG_COMPLEX)
        self.assertEqual(value & ((1 << 64) - 1), encoding.float_bits(1.5))
        self.assertEqual(value >> 64, encoding.float_bits(-2.25))

    def test_range_layouts(self) -> None:
        tag, value = encoding.make_range_inline(-1, 7, 2)
        self.assertEqual(tag, encoding.TAG_RANGE)
        self.assertEqual((value >> 64) & 0xFFFF_FFFF, 0xFFFF_FFFF)
        self.assertEqual((value >> 32) & 0xFFFF_FFFF, 7)
        self.assertEqual(value & 0xFFFF_FFFF, 2)
        tag, value = encoding.make_range_tuple(0x880)
        self.assertEqual(tag, encoding.TAG_RANGE)
        self.assertEqual(value >> 127, 1)
        self.assertEqual(value & ((1 << 64) - 1), 0x880)

    def test_tag_constant_rejects_non_inline_range_without_heap(self) -> None:
        strings = encoding.StringHeapBuilder()
        with self.assertRaisesRegex(ValueError, "heap tuple"):
            encoding.tag_constant(range(0, 1 << 40), strings)


class TestTagConstantNoneAndContainers(unittest.TestCase):
    def test_none_is_control_none(self) -> None:
        heap = preprocess.StringHeapBuilder()
        tag, val = preprocess.tag_constant(None, heap)
        self.assertEqual(tag, preprocess.TAG_CONTROL)
        self.assertEqual(val, 1)

    def test_tuple_raises(self) -> None:
        heap = preprocess.StringHeapBuilder()
        with self.assertRaises(ValueError) as ctx:
            preprocess.tag_constant((1, 2), heap)
        self.assertIn("static heap image builder", str(ctx.exception))

    def test_list_raises(self) -> None:
        heap = preprocess.StringHeapBuilder()
        with self.assertRaises(ValueError):
            preprocess.tag_constant([1], heap)

    def test_frozenset_raises(self) -> None:
        heap = preprocess.StringHeapBuilder()
        with self.assertRaises(ValueError):
            preprocess.tag_constant(frozenset({1}), heap)


class TestStringHeapInterning(unittest.TestCase):
    def test_identical_long_strings_share_address(self) -> None:
        heap = preprocess.StringHeapBuilder()
        s = "abcdefghijklmnop"  # 16 bytes
        t1, v1 = preprocess.tag_constant(s, heap)
        t2, v2 = preprocess.tag_constant(s, heap)
        self.assertEqual(t1, preprocess.TAG_LONG_STR)
        self.assertEqual(t2, preprocess.TAG_LONG_STR)
        self.assertEqual(v1, v2)
        addr1 = v1 & ((1 << 64) - 1)
        addr2 = v2 & ((1 << 64) - 1)
        self.assertEqual(addr1, addr2)
        # Only one copy in the image.
        self.assertEqual(heap.next_addr, len(s.encode("utf-8")))


class TestControlKeyPacking(unittest.TestCase):
    def test_none_dict_key_carries_control_id_in_tag_word(self) -> None:
        builder = heap_image.HeapImageBuilder()
        handle = builder.alloc_dict(
            [(encoding.make_none(), (encoding.TAG_INT, 7))],
            slot_count=4,
        )
        obj = encoding.mut_addr(handle[1])
        table = builder.words[obj + 32] & ((1 << 64) - 1)
        # hash(CONTROL/NONE value=1) & 3 = slot 1.
        self.assertEqual(builder.words[table + 16 + 64], 0x10)
        # Other empty key-tag slots remain exactly zero.
        self.assertEqual(builder.words[table + 16], 0)


class TestBuildTupleAccepted(unittest.TestCase):
    def setUp(self) -> None:
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    return (a, b)\n"
        )

    def test_build_tuple_in_opnames(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        opnames = [e.opname for e in emitted]
        self.assertIn("BUILD_TUPLE", opnames)

    def test_build_tuple_single_slot(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        slot_map = preprocess.compute_slot_map(emitted)
        for i, e in enumerate(emitted):
            if e.opname == "BUILD_TUPLE":
                self.assertEqual(slot_map[i + 1] - slot_map[i], 1)

    def test_type_sketch_pushes_tuple(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        # Store into a local to observe the tag.
        fn2 = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    t = (a, b)\n"
            "    return t\n"
        )
        emitted2 = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(fn2),
            co_consts=fn2.__code__.co_consts,
            string_heap=preprocess.StringHeapBuilder(),
        )
        var_tags, _ = preprocess.infer_types(fn2, emitted2)
        self.assertEqual(var_tags.get("t"), preprocess.TAG_TUPLE)

    def test_opcode_number(self) -> None:
        self.assertEqual(preprocess.OP_BUILD_TUPLE, 51)


class TestDictKeyHashAgreement(unittest.TestCase):
    """Python-side hash must match documented RTL vectors (Part 4.4 / 2.1)."""

    def test_int_bool(self) -> None:
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_INT, 7), 7)
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_BOOL, 1), 1)
        # CPython: hash(-1) == -2
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_INT, (-1) & ((1 << 128) - 1)),
            0xFFFFFFFE,
        )
        # True and 1 share a hash (cross-tag rich-eq path in excore).
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_BOOL, 1),
            heap_image.dict_key_hash(heap_image.TAG_INT, 1),
        )
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_BOOL, 0), 0)

    def test_float_integer_valued(self) -> None:
        from encoding import float_bits

        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_FLOAT, float_bits(1.0)), 1
        )
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_FLOAT, float_bits(-1.0)),
            0xFFFFFFFE,
        )
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_FLOAT, float_bits(0.0)), 0
        )
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_FLOAT, float_bits(-0.0)), 0
        )
        self.assertEqual(
            heap_image.dict_key_hash(heap_image.TAG_FLOAT, float_bits(2.0)), 2
        )

    def test_short_str_fold(self) -> None:
        # "x" encoded the same way as preprocess / RTL SHORT_STR layout.
        val = heap_image.encode_short_str(b"x")
        # Manual XOR of four 32-bit words.
        w0 = val & 0xFFFFFFFF
        w1 = (val >> 32) & 0xFFFFFFFF
        w2 = (val >> 64) & 0xFFFFFFFF
        w3 = (val >> 96) & 0xFFFFFFFF
        expected = (w0 ^ w1 ^ w2 ^ w3) & 0xFFFFFFFF
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_SHORT_STR, val), expected)
        # Documented vector: size nibble in [127:124], 'x'=0x78 in first data byte.
        # size=1 → bits[127:124]=1 → w3 = 0x10000000 | ...
        self.assertEqual(val >> 124, 1)

    def test_long_str(self) -> None:
        # size=16, addr=0x20 → value = (16 << 64) | 0x20
        # hash = value[31:0] ^ value[95:64] = 0x20 ^ 16 = 0x30
        val = (16 << 64) | 0x20
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_LONG_STR, val), 0x30)

    def test_collision_keys(self) -> None:
        # Keys 0 and 4 collide under slot_count 4 (mask 3).
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_INT, 0) & 3, 0)
        self.assertEqual(heap_image.dict_key_hash(heap_image.TAG_INT, 4) & 3, 0)


class TestListObjectBufferLayout(unittest.TestCase):
    """Phase A: growable split object/buffer LIST layout (see pycore_defs.svh)."""

    def test_empty_list_is_object_only(self) -> None:
        builder = heap_image.HeapImageBuilder()
        tag, value = builder.alloc_list([])
        self.assertEqual(tag, heap_image.TAG_MUT_COLLEC)
        self.assertEqual(heap_image.mut_kind(value), heap_image.MUT_LIST)
        obj_addr = heap_image.mut_addr(value)
        # header {capacity=0, length=0}
        self.assertEqual(builder.words[obj_addr], 0)
        # ob_item = 0 (no buffer allocated)
        self.assertEqual(builder.words[obj_addr + 16], 0)
        # Exactly the 32-byte object was allocated.
        self.assertEqual(builder.end_ptr, obj_addr + 32)

    def test_nonempty_list_object_and_buffer_addresses(self) -> None:
        builder = heap_image.HeapImageBuilder()
        elements = [(heap_image.TAG_INT, 7), (heap_image.TAG_INT, 9)]
        tag, value = builder.alloc_list(elements)
        self.assertEqual(tag, heap_image.TAG_MUT_COLLEC)
        self.assertEqual(heap_image.mut_kind(value), heap_image.MUT_LIST)
        obj_addr = heap_image.mut_addr(value)

        header = builder.words[obj_addr]
        capacity = header >> 64
        length = header & ((1 << 64) - 1)
        self.assertEqual(capacity, 2)
        self.assertEqual(length, 2)

        ob_item = builder.words[obj_addr + 16]
        # Buffer immediately follows the 32-byte object.
        self.assertEqual(ob_item, obj_addr + 32)

        # Element 0 at ob_item+0 (value) / ob_item+16 (tag).
        self.assertEqual(builder.words[ob_item], 7)
        self.assertEqual(builder.words[ob_item + 16], heap_image.TAG_INT)
        # Element 1 at ob_item+32 (value) / ob_item+48 (tag).
        self.assertEqual(builder.words[ob_item + 32], 9)
        self.assertEqual(builder.words[ob_item + 48], heap_image.TAG_INT)

        # Total allocation: 32 (object) + 2*32 (buffer).
        self.assertEqual(builder.end_ptr, obj_addr + 32 + 64)

    def test_alias_same_handle_round_trips(self) -> None:
        """Two RF slots referencing the same list handle name the same object.

        This is the prerequisite the split object/buffer design exists for:
        growth only ever rewrites the object's ob_item field, so any alias
        that stored the (tag, obj_addr) handle keeps working after growth
        because it never stored a buffer address directly.
        """
        builder = heap_image.HeapImageBuilder()
        list_handle = builder.alloc_list([(heap_image.TAG_INT, 1)])

        # Nest the same handle twice inside an outer list (two aliases).
        outer_tag, outer_value = builder.alloc_list([list_handle, list_handle])
        self.assertEqual(outer_tag, heap_image.TAG_MUT_COLLEC)
        outer_addr = heap_image.mut_addr(outer_value)

        outer_ob_item = builder.words[outer_addr + 16]
        alias_0 = builder.words[outer_ob_item]        # element 0 value field
        alias_1 = builder.words[outer_ob_item + 32]    # element 1 value field
        self.assertEqual(alias_0, list_handle[1])
        self.assertEqual(alias_1, list_handle[1])
        self.assertEqual(alias_0, alias_1)

        # Both aliases' tag slots name MUT_COLLEC; values retain MUT_LIST.
        self.assertEqual(
            builder.words[outer_ob_item + 16], heap_image.TAG_MUT_COLLEC
        )
        self.assertEqual(
            builder.words[outer_ob_item + 48], heap_image.TAG_MUT_COLLEC
        )
        self.assertEqual(
            heap_image.mut_kind(builder.words[outer_ob_item]),
            heap_image.MUT_LIST,
        )


class TestListWithSpareCapacity(unittest.TestCase):
    """alloc_list_with_capacity: hand-set spare capacity for LIST_APPEND
    fast-path fixtures (BUILD_LIST itself never produces capacity > length)."""

    def test_capacity_greater_than_length(self) -> None:
        builder = heap_image.HeapImageBuilder()
        tag, value = builder.alloc_list_with_capacity(
            [(heap_image.TAG_INT, 7)], capacity=4
        )
        self.assertEqual(tag, heap_image.TAG_MUT_COLLEC)
        self.assertEqual(heap_image.mut_kind(value), heap_image.MUT_LIST)
        obj_addr = heap_image.mut_addr(value)
        header = builder.words[obj_addr]
        capacity = header >> 64
        length = header & ((1 << 64) - 1)
        self.assertEqual(capacity, 4)
        self.assertEqual(length, 1)

        ob_item = builder.words[obj_addr + 16]
        self.assertEqual(ob_item, obj_addr + 32)
        # Buffer reserved for 4 elements (128 bytes), only element 0 written.
        self.assertEqual(builder.end_ptr, ob_item + 4 * 32)
        self.assertEqual(builder.words[ob_item], 7)
        self.assertEqual(builder.words.get(ob_item + 32, 0), 0)

    def test_capacity_less_than_length_rejected(self) -> None:
        builder = heap_image.HeapImageBuilder()
        with self.assertRaises(ValueError):
            builder.alloc_list_with_capacity(
                [(heap_image.TAG_INT, 1), (heap_image.TAG_INT, 2)], capacity=1
            )


if __name__ == "__main__":
    unittest.main()
