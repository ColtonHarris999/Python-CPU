"""Unit tests for string constant encoding in pycore preprocess."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

from pycore.tools import preprocess


class PreprocessStringEncodingTest(unittest.TestCase):
    def test_short_string_encoding_layout(self) -> None:
        heap = preprocess.StringHeapBuilder()
        tag, value = preprocess.tag_constant("abc", heap)

        self.assertEqual(tag, preprocess.TAG_SHORT_STR)
        self.assertEqual((value >> preprocess.SHORT_STR_SIZE_SHIFT) & 0xF, 3)

        payload = (value >> preprocess.SHORT_STR_DATA_SHIFT) & ((1 << 120) - 1)
        self.assertEqual((payload >> 112) & 0xFF, ord("a"))
        self.assertEqual((payload >> 104) & 0xFF, ord("b"))
        self.assertEqual((payload >> 96) & 0xFF, ord("c"))
        self.assertEqual(heap.image, {})

    def test_long_string_allocates_in_memory_region(self) -> None:
        long_value = "xyz" * 8  # 24 bytes > 15-byte short-string inline payload
        heap = preprocess.StringHeapBuilder()
        tag, value = preprocess.tag_constant(long_value, heap)

        self.assertEqual(tag, preprocess.TAG_LONG_STR)
        size = (value >> 64) & ((1 << 64) - 1)
        addr = value & ((1 << 64) - 1)
        self.assertEqual(size, len(long_value))
        self.assertEqual(addr, 0)
        for idx, byte in enumerate(long_value.encode("utf-8")):
            self.assertEqual(heap.image[idx], byte)

    def test_write_string_hex_emits_addressed_image(self) -> None:
        heap = preprocess.StringHeapBuilder()
        preprocess.tag_constant("A" * 20, heap)
        preprocess.tag_constant("B" * 19, heap)
        heap.image[128] = 0x33  # force a sparse jump and an @address marker

        with tempfile.TemporaryDirectory() as tmpdir:
            path = pathlib.Path(tmpdir) / "strings.hex"
            preprocess.write_string_hex(path, heap)
            text = path.read_text(encoding="ascii")

        self.assertIn("@80", text)  # 128 decimal
        self.assertIn("41", text)  # 'A'
        self.assertIn("42", text)  # 'B'
        self.assertIn("33", text)

    def test_string_add_type_inference(self) -> None:
        self.assertEqual(
            preprocess.merge_numeric(preprocess.TAG_SHORT_STR, preprocess.TAG_LONG_STR, 0),
            preprocess.TAG_LONG_STR,
        )
        self.assertEqual(
            preprocess.merge_numeric(preprocess.TAG_SHORT_STR, preprocess.TAG_LONG_STR, 13),
            preprocess.TAG_LONG_STR,
        )


if __name__ == "__main__":
    unittest.main()
