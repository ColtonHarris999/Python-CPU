"""The committed catalog matches the pinned MicroPython headers."""

import json
import unittest

from catalog_from_headers import CATALOG_PATH, build_catalog


class CatalogTests(unittest.TestCase):
    def test_mpy_version_matches_headers(self):
        recorded = json.loads(CATALOG_PATH.read_text())
        live = build_catalog()
        self.assertEqual(recorded, live)
        pinned = recorded["micropython"]
        self.assertEqual(pinned["tag"], "v1.29.0")
        self.assertEqual(pinned["mpy_version"], live["micropython"]["mpy_version"])
        self.assertEqual(pinned["mpy_sub_version"], live["micropython"]["mpy_sub_version"])
        self.assertEqual(pinned["mpy_version"], 6)
        self.assertEqual(pinned["mpy_sub_version"], 3)
        self.assertEqual(recorded["object_word"]["repr"], "A")
        self.assertEqual(recorded["object_word"]["small_int"]["shift"], 1)
        self.assertEqual(pinned["small_int_bits"], 31)


if __name__ == "__main__":
    unittest.main()
