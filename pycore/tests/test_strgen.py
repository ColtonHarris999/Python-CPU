"""strgen.py CPython-vs-model differential (P5a gate).

The harness runs ~24k cases/second host-side, so the CI budget is generous:
eight seeds x 400 cases covers every op and variant (including REPLACE, JOIN,
and the isdecimal/isnumeric classifiers, which earlier runs never generated).
A longer sweep is available on demand via `strgen.py --seed N --n M`.
"""

from __future__ import annotations

import unittest

from pycore.tools import strgen


class TestStrgen(unittest.TestCase):
    def test_seeded_corpus(self) -> None:
        for seed in range(1, 9):
            with self.subTest(seed=seed):
                self.assertEqual(strgen.main(["--seed", str(seed), "--n", "400"]), 0)
