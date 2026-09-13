"""strgen.py CPython-vs-model differential (P5a gate)."""

from __future__ import annotations

import random
import unittest

from pycore.tools.encoding import (
    HEAP_BASE,
    SA_CLASSIFY,
    SA_IS_DECIMAL,
    SA_IS_NUMERIC,
    SA_JOIN,
    SA_REPLACE,
)
from pycore.tools.strmodel import StrAccel

from pycore.tools import strgen


class TestStrgen(unittest.TestCase):
    def test_seeded_corpus(self) -> None:
        self.assertEqual(strgen.main(["--seed", "1", "--n", "400"]), 0)

    def test_second_seed(self) -> None:
        self.assertEqual(strgen.main(["--seed", "7", "--n", "400"]), 0)

    def test_extra_seeds(self) -> None:
        for seed in (13, 19, 23, 29, 31, 37):
            with self.subTest(seed=seed):
                self.assertEqual(strgen.main(["--seed", str(seed), "--n", "400"]), 0)

    def test_replace_join_classify_actually_run(self) -> None:
        seen: set[tuple[int, int]] = set()
        rng = random.Random(1)
        accel = StrAccel()
        heap = HEAP_BASE
        for _ in range(2000):
            heap = strgen.run_case(rng, accel, heap, seen)
        required = {
            (SA_REPLACE, 0),
            (SA_JOIN, 0),
            (SA_CLASSIFY, SA_IS_DECIMAL),
            (SA_CLASSIFY, SA_IS_NUMERIC),
        }
        missing = required - seen
        self.assertFalse(missing, f"differential never executed {missing}")
