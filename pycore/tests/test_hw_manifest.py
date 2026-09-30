"""hw_tests.toml is well formed: every hardware test points at real files.

The simulator runs live in the per-area CI jobs; this catches a typo in the
manifest in seconds, in the host-tools job.
"""

from __future__ import annotations

import pathlib
import re
import unittest

import hw_tests

ROOT = pathlib.Path(__file__).resolve().parents[2]
AREAS = {
    "alu", "strings", "containers", "control-flow", "calls", "objects",
    "variables", "exceptions", "builtins", "memory", "excore", "compiler",
}


class HwManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tests = hw_tests.load_manifest()

    def test_areas_match_the_makefile_and_ci(self) -> None:
        self.assertEqual(set(hw_tests.areas_of(self.tests)), AREAS)
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        m = re.search(r"^HW_AREAS := ((?:.*\\\n)*.*)$", makefile, re.M)
        assert m is not None
        self.assertEqual(set(m.group(1).replace("\\\n", " ").split()), AREAS)
        workflow = (ROOT / ".github" / "workflows" / "all-tests.yml").read_text(encoding="utf-8")
        m = re.search(r"area: \[([^\]]*)\]", workflow)
        assert m is not None
        self.assertEqual({a.strip() for a in m.group(1).split(",")}, AREAS)

    def test_old_target_names_are_unique(self) -> None:
        names = [t.legacy_target for t in self.tests]
        self.assertEqual(len(names), len(set(names)))

    def test_every_test_points_at_real_files(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        for t in self.tests:
            with self.subTest(test=t.name):
                if t.kind == "make":
                    self.assertRegex(makefile, rf"(?m)^{re.escape(t.target or '')}:")
                    continue
                if t.kind in ("run", "trap", "stdout", "coderam"):
                    self.assertTrue(t.source.is_file(), t.source)
                    self.assertIsNotNone(t.cycles)
                if t.kind == "trap":
                    self.assertIsNotNone(t.trap)
                if t.kind == "stdout":
                    self.assertTrue((hw_tests.PROGRAMS / f"img_{t.src}.stdout").is_file())
                if t.kind == "container":
                    self.assertIsNotNone(t.hex)
                if t.kind in ("container_boot", "excore"):
                    self.assertIsNotNone(t.stem)
                for need in t.needs:
                    self.assertRegex(makefile, rf"(?m)^{re.escape(need)}:")

    def test_caching_sample_is_compiler_only(self) -> None:
        sample = [t for t in self.tests if t.caching]
        self.assertTrue(sample)
        for t in sample:
            self.assertEqual(t.area, "compiler", t.name)


if __name__ == "__main__":
    unittest.main()
