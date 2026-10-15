"""Benchmark files are written for a suite run, and CI still gates on all-tests."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

import bench_report

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "all-tests.yml"


class BenchReportTest(unittest.TestCase):
    def test_write_benchmark_records_a_readable_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp)
            path = bench_report.write_benchmark(
                "hw-alu",
                [
                    {"status": "PASS", "area": "alu", "name": "add", "config": "cache=1 lat=4", "cycles": 10},
                    {"status": "FAIL", "area": "alu", "name": "slow", "config": "cache=1 lat=4",
                     "cycles": 90, "detail": "boom | now"},
                ],
                elapsed_s=1.25,
                passed=1,
                failed=1,
                out_dir=out,
            )
            text = path.read_text(encoding="utf-8")
            self.assertIn("# Benchmark hw-alu", text)
            self.assertIn("1 passed, 1 failed", text)
            # Slowest cycle count first, and a pipe in the detail cannot break the table.
            slow = text.index("slow")
            add = text.index("| PASS | alu | add")
            self.assertLess(slow, add)
            self.assertIn("boom / now", text)
            payload = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
            self.assertEqual(payload["suite"], "hw-alu")
            self.assertEqual(payload["rows"][0]["cycles"], 10)
            self.assertEqual((out / "latest.md").read_text(encoding="utf-8"), text)
            index = (out / "index.md").read_text(encoding="utf-8")
            self.assertIn("`%s`" % path.name, index)
            # A second run appends instead of replacing the first file.
            second = bench_report.write_benchmark(
                "host-tests", [], elapsed_s=0.1, passed=0, failed=0, out_dir=out,
            )
            self.assertTrue(path.is_file())
            self.assertNotEqual(path, second)
            self.assertEqual(index.count("\n"), (out / "index.md").read_text(encoding="utf-8").count("\n") - 1)

    def test_all_tests_check_stays_the_main_gate(self) -> None:
        """The main ruleset requires a successful check named all-tests.

        A pull-request title or body edit must not share the concurrency
        group of the real run: that second run has failed before creating
        any job, and the ruleset then treats all-tests as missing.
        """
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("\n  all-tests:\n    name: all-tests\n", text)
        concurrency = text.split("jobs:", 1)[0]
        self.assertNotIn("github.event.changes", concurrency)
        self.assertIn("ci-edit-", concurrency)
        self.assertIn("name: benchmark-results", text)
        # The benchmark publish step must not be able to fail the required check.
        gate = text.split("name: all-tests", 1)[1]
        self.assertIn("continue-on-error: true", gate)
        self.assertLess(gate.index("Require every job that ran"), gate.index("benchmark-results"))


if __name__ == "__main__":
    unittest.main()
