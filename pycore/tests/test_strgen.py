"""strgen.py CPython-vs-model differential (P5a gate)."""

from __future__ import annotations

import unittest

from pycore.tools import strgen


class TestStrgen(unittest.TestCase):
    def test_seeded_corpus(self) -> None:
        self.assertEqual(strgen.main(["--seed", "1", "--n", "80"]), 0)

    def test_second_seed(self) -> None:
        self.assertEqual(strgen.main(["--seed", "7", "--n", "80"]), 0)
