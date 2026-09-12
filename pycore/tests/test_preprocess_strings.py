"""Unit tests for string constant encoding in pycore preprocess."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

from pycore.tools import heap_image, preprocess
from pycore.tools.encoding import HEAP_BASE, stracc_unpack_long_handle


class PreprocessStringEncodingTest(unittest.TestCase):
    def test_short_string_encoding_layout(self) -> None:
        tag, value = preprocess.tag_constant("abc")

        self.assertEqual(tag, preprocess.TAG_SHORT_STR)
        self.assertEqual((value >> preprocess.SHORT_STR_SIZE_SHIFT) & 0xF, 3)

        payload = (value >> preprocess.SHORT_STR_DATA_SHIFT) & ((1 << 120) - 1)
        self.assertEqual((payload >> 112) & 0xFF, ord("a"))
        self.assertEqual((payload >> 104) & 0xFF, ord("b"))
        self.assertEqual((payload >> 96) & 0xFF, ord("c"))

    def test_long_string_allocates_heap_object(self) -> None:
        long_value = "xyz" * 8  # 24 bytes > 15-byte short-string inline payload
        heap = heap_image.HeapImageBuilder()
        tag, value = preprocess.tag_constant(long_value, heap)

        self.assertEqual(tag, preprocess.TAG_LONG_STR)
        fields = stracc_unpack_long_handle(value)
        self.assertEqual(fields["nchars"], len(long_value))
        addr = fields["addr"]
        self.assertGreaterEqual(addr, HEAP_BASE)
        payload = bytes(
            (heap.words.get((addr + 16 + i) & ~15, 0) >> (8 * ((addr + 16 + i) & 15)))
            & 0xFF
            for i in range(len(long_value))
        )
        self.assertEqual(payload, long_value.encode("latin-1"))

    def test_write_string_hex_is_legacy_stub(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = pathlib.Path(tmpdir) / "strings.hex"
            preprocess.write_string_hex(path, None)
            text = path.read_text(encoding="ascii")
        self.assertEqual(text, "00\n")

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
