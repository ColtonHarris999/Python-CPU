"""Tests for the research-manager lint / help CLI."""

from __future__ import annotations

import io
import os
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock


_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_TOOLS_DIR = _REPO_ROOT / "pycore" / "tools"
sys.path.insert(0, str(_TOOLS_DIR))

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("pycore_cli tests require Python 3.14")

import pycore_cli  # noqa: E402


class HelpTest(unittest.TestCase):
    def test_help_command_prints_summary_and_usage(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = pycore_cli.main(["help"])
        text = buf.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("What a program may look like", text)
        self.assertIn("Not supported yet", text)
        self.assertIn("pycore_cli.py lint", text)
        self.assertIn("make run-file", text)

    def test_no_args_prints_help(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = pycore_cli.main([])
        self.assertEqual(rc, 0)
        self.assertIn("What a program may look like", buf.getvalue())
        self.assertIn("managed_entry", buf.getvalue())


class LintGoodProgramsTest(unittest.TestCase):
    def test_example_sum_loop_lints_clean(self) -> None:
        path = _REPO_ROOT / "pycore" / "programs" / "example_sum_loop.py"
        errors = pycore_cli.lint_path(path)
        self.assertEqual(errors, [])

    def test_img_return_true_lints_clean(self) -> None:
        path = _REPO_ROOT / "pycore" / "programs" / "img_return_true.py"
        errors = pycore_cli.lint_path(path)
        self.assertEqual(errors, [])

    def test_smoke_return_without_module_call_lints_clean(self) -> None:
        path = _REPO_ROOT / "pycore" / "programs" / "smoke_return.py"
        errors = pycore_cli.lint_path(path)
        self.assertEqual(errors, [])

    def test_lint_cli_ok_exit(self) -> None:
        path = str(_REPO_ROOT / "pycore" / "programs" / "example_sum_loop.py")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = pycore_cli.main(["lint", path])
        self.assertEqual(rc, 0)
        self.assertIn("Lint OK", buf.getvalue())


class LintRejectedProgramsTest(unittest.TestCase):
    def _lint_snippet(self, source: str) -> list[str]:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False, encoding="utf-8"
        ) as handle:
            handle.write(source)
            path = pathlib.Path(handle.name)
        try:
            return pycore_cli.lint_path(path)
        finally:
            path.unlink(missing_ok=True)

    def test_import_is_rejected(self) -> None:
        errors = self._lint_snippet(
            "import math\n\ndef managed_entry():\n    return 1\n"
        )
        self.assertTrue(any("IMPORT_NAME" in e for e in errors), errors)

    def test_yield_is_rejected(self) -> None:
        errors = self._lint_snippet(
            "def gen():\n    yield 1\n\ndef managed_entry():\n    return 1\n"
        )
        self.assertTrue(
            any("YIELD_VALUE" in e or "generator" in e.lower() for e in errors),
            errors,
        )

    def test_assert_is_rejected(self) -> None:
        errors = self._lint_snippet(
            "def managed_entry():\n    x = 1\n    assert x\n    return 1\n"
        )
        self.assertTrue(
            any("LOAD_COMMON_CONSTANT" in e or "assert" in e.lower() for e in errors),
            errors,
        )

    def test_literal_slice_constant_is_rejected(self) -> None:
        errors = self._lint_snippet(
            'def managed_entry():\n    s = "abcde"\n    return len(s[1:3])\n'
        )
        self.assertTrue(errors, "expected literal slice to fail lint")
        blob = " ".join(errors).lower()
        self.assertTrue(
            "slice" in blob or "unsupported constant" in blob,
            errors,
        )

    def test_multiple_deferred_opcodes_are_all_reported(self) -> None:
        errors = self._lint_snippet(
            "import math\n"
            "def gen():\n"
            "    yield 1\n"
            "def managed_entry():\n"
            "    return 1\n"
        )
        blob = " ".join(errors)
        self.assertIn("IMPORT_NAME", blob)
        self.assertTrue("YIELD_VALUE" in blob or "generator" in blob.lower(), errors)

    def test_missing_file(self) -> None:
        errors = pycore_cli.lint_path(pathlib.Path("/tmp/pycore-does-not-exist.py"))
        self.assertEqual(len(errors), 1)
        self.assertIn("not found", errors[0])

    def test_lint_cli_fail_exit(self) -> None:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False, encoding="utf-8"
        ) as handle:
            handle.write("import os\n")
            path = handle.name
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = pycore_cli.main(["lint", path])
            self.assertEqual(rc, 1)
            self.assertIn("Lint FAIL", buf.getvalue())
        finally:
            os.unlink(path)


class EnsureEntryCallTest(unittest.TestCase):
    def test_appends_call_when_missing(self) -> None:
        src = "def managed_entry():\n    return 12\n"
        out = pycore_cli.ensure_entry_call(src, "managed_entry")
        self.assertTrue(out.rstrip().endswith("managed_entry()"))

    def test_does_not_duplicate_existing_call(self) -> None:
        src = "def managed_entry():\n    return 12\n\nmanaged_entry()\n"
        self.assertEqual(pycore_cli.ensure_entry_call(src, "managed_entry"), src)


class RunHostGoldenGateTest(unittest.TestCase):
    def test_run_stops_on_lint_failure(self) -> None:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False, encoding="utf-8"
        ) as handle:
            handle.write("import os\n\ndef managed_entry():\n    return 1\n")
            path = handle.name
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = pycore_cli.main(["run", path, "--build-dir", "build/pycore_cli_test"])
            self.assertEqual(rc, 1)
            self.assertIn("Lint FAIL", buf.getvalue())
        finally:
            os.unlink(path)

    def test_run_does_not_invoke_verilator_when_host_entry_is_wrong_type(self) -> None:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False, encoding="utf-8"
        ) as handle:
            handle.write("def managed_entry():\n    return [1, 2]\n")
            path = handle.name
        try:
            buf = io.StringIO()
            with redirect_stdout(buf), mock.patch.object(
                pycore_cli, "_run_verilator"
            ) as verilator:
                rc = pycore_cli.main(
                    ["run", path, "--build-dir", "build/pycore_cli_test_bad_ret"]
                )
            self.assertEqual(rc, 1)
            verilator.assert_not_called()
            self.assertIn("Host golden FAIL", buf.getvalue())
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
