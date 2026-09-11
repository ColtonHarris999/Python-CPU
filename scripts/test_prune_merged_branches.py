#!/usr/bin/env python3
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from prune_merged_branches import classify


class ClassifyTests(unittest.TestCase):
    def test_protected_wins_over_merged(self):
        self.assertEqual(
            classify("excore", {"main", "ui", "excore"}, set(), 40, 10, "diverged"),
            "keep-protected",
        )

    def test_parked_ui_wins_over_closed_pr(self):
        self.assertEqual(
            classify("ui", {"main", "ui", "excore"}, set(), 62, 18, "diverged"),
            "keep-protected",
        )

    def test_open_pr_is_kept(self):
        self.assertEqual(
            classify(
                "cursor/slice-const-fold-7edc",
                {"main", "ui"},
                {"cursor/slice-const-fold-7edc"},
                None,
                2,
                "diverged",
            ),
            "keep-open",
        )

    def test_merged_pr_is_pruned(self):
        self.assertEqual(
            classify("pycore_firmware", {"main", "ui"}, set(), 52, 0, "behind"),
            "prune-merged-pr",
        )

    def test_zero_ahead_without_pr_is_pruned(self):
        self.assertEqual(
            classify("stale", {"main", "ui"}, set(), None, 0, "behind"),
            "prune-merged",
        )

    def test_closed_unmerged_is_kept(self):
        self.assertEqual(
            classify(
                "cursor/paper-architecture-overview-ee06",
                {"main", "ui"},
                set(),
                None,
                10,
                "diverged",
            ),
            "keep-unmerged",
        )


if __name__ == "__main__":
    unittest.main()
