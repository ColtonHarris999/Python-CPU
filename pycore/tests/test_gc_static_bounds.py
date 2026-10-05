"""The static prune map stays inside PYCORE_GC_STATIC_MAP_BYTES.

The map has one bit per granule of the first 1 MB. The run table follows
it, so a map word written past the region for a larger static image would
be overwritten by the sweep and read back as premarks.
"""

from __future__ import annotations

import unittest
from unittest import mock

from pycore.tools import gc_model, gc_static
from pycore.tools.encoding import GC_STATIC_MAP, GC_STATIC_MAP_BYTES


class StaticMapBounds(unittest.TestCase):
    def test_prune_map_never_leaves_its_region(self):
        # One prunable object every 4 KB across a 4 MB static image.
        kind_of = {a: "TUPLE" for a in range(0x1000, 4 << 20, 0x1000)}
        with mock.patch.object(gc_static, "kept_objects", return_value=(kind_of, set())):
            out = gc_static.prune_map({}, 4 << 20)
        self.assertTrue(out)
        for w in out:
            self.assertGreaterEqual(w, GC_STATIC_MAP)
            self.assertLess(w, GC_STATIC_MAP + GC_STATIC_MAP_BYTES)
        pruned = {g for w, bits in out.items()
                  for g in range(((w - GC_STATIC_MAP) // 16) << 7, (((w - GC_STATIC_MAP) // 16) + 1) << 7)
                  if bits >> (g & 127) & 1}
        self.assertEqual(pruned, {a >> 4 for a in kind_of if a < GC_STATIC_MAP_BYTES * 8 * 16})

    def test_oracle_ignores_words_past_the_region(self):
        words = {GC_STATIC_MAP: 1, GC_STATIC_MAP + GC_STATIC_MAP_BYTES: 1}
        self.assertEqual(gc_model.pruned_granules(words), {0})


if __name__ == "__main__":
    unittest.main()
