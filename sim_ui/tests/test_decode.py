"""Unit tests for tagged-value decode helpers (no Verilator)."""

from __future__ import annotations

import unittest

from sim_ui.server.decode import (
    TAG_INT,
    TAG_MUT_COLLEC,
    decode_entry,
    decode_entry_hex,
    make_list,
    mut_contaminated,
    parse_entry_hex,
    trap_name,
)


class DecodeTests(unittest.TestCase):
    def test_int_display(self) -> None:
        d = decode_entry(TAG_INT, 42)
        self.assertEqual(d["tag"], "INT")
        self.assertEqual(d["display"], "42")

    def test_parse_entry_hex_roundtrip(self) -> None:
        tag, value = make_list(0x500, contaminated=True)
        raw = (tag << 128) | value
        hex_str = f"{raw:033x}"
        t2, v2 = parse_entry_hex(hex_str)
        self.assertEqual(t2, TAG_MUT_COLLEC)
        self.assertTrue(mut_contaminated(v2))
        d = decode_entry_hex(hex_str)
        self.assertEqual(d["kind"], "LIST")
        self.assertTrue(d["contaminated"])
        self.assertEqual(d["addr"], 0x500)

    def test_trap_names_include_bulk(self) -> None:
        self.assertEqual(trap_name(19), "DICT_UPDATE")
        self.assertEqual(trap_name(20), "DICT_MERGE")
        self.assertEqual(trap_name(10), "LIST_EXTEND")


if __name__ == "__main__":
    unittest.main()
