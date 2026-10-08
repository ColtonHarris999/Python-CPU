"""Host lock for the key specification."""

from __future__ import annotations

import unittest

from pycore.tools.encoding import TAG_INT, TAG_LONG_STR, dict_key_hash
from pycore.tools.keyspec import key_hash, need_payload_cmp


class TestKeyspec(unittest.TestCase):
    def test_int_minus_one_hashes_to_minus_two(self) -> None:
        self.assertEqual(key_hash(TAG_INT, (1 << 64) - 1), 0xFFFFFFFE)
        self.assertEqual(key_hash(TAG_INT, (1 << 64) - 1), dict_key_hash(TAG_INT, (1 << 64) - 1))

    def test_long_str_hash_is_the_cached_word(self) -> None:
        value = (0xA5A5A5A5 << 64) | 0x1000
        self.assertEqual(key_hash(TAG_LONG_STR, value), 0xA5A5A5A5)

    def test_distinct_long_str_same_hash_needs_payload(self) -> None:
        a = (0x1111 << 64) | 0x1000
        b = (0x1111 << 64) | 0x2000
        self.assertTrue(need_payload_cmp(TAG_LONG_STR, a, TAG_LONG_STR, b))
        self.assertFalse(need_payload_cmp(TAG_LONG_STR, a, TAG_LONG_STR, a))


if __name__ == "__main__":
    unittest.main()
