"""Host gate for ``pycore_firmware/compiler/`` (compiler_design.md step A).

The tree must stay inside the PyCore subset. Known-bad snippets are red so
the checker cannot silently go no-op.
"""

from __future__ import annotations

import pathlib
import sys
import tempfile
import textwrap
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler subset tests require Python 3.14")

import compiler_subset


def _violations(src: str) -> list[compiler_subset.SubsetViolation]:
    return compiler_subset.check_source(textwrap.dedent(src), filename="<fixture>")


def _messages(src: str) -> str:
    return "\n".join(v.message for v in _violations(src))


class CheckerCatchesBannedConstructs(unittest.TestCase):
    def test_negative_index_is_red(self) -> None:
        src = """
        def f():
            xs = [1, 2, 3]
            return xs[-1]
        """
        self.assertIn("negative index", _messages(src))

    def test_list_slice_is_red(self) -> None:
        src = """
        def f():
            xs = [1, 2, 3, 4]
            return xs[1:]
        """
        self.assertIn("list/tuple slice", _messages(src))

    def test_class_is_red(self) -> None:
        src = """
        class C:
            pass
        """
        self.assertIn("class is banned", _messages(src))

    def test_closure_is_red(self) -> None:
        src = """
        def outer():
            x = 1
            def inner():
                return x
            return inner
        """
        text = _messages(src)
        self.assertTrue(
            "freevars" in text or "cellvars" in text,
            text,
        )

    def test_over_cap_frame_window_is_red(self) -> None:
        assigns = "\n".join(f"    x{i} = {i}" for i in range(220))
        src = f"def f():\n{assigns}\n    return x0\n"
        self.assertIn("frame window", _messages(src))

    def test_fstring_is_red(self) -> None:
        src = """
        def f(x):
            return f"{x}"
        """
        self.assertIn("f-string", _messages(src))

    def test_import_is_red(self) -> None:
        src = "import ast\n"
        self.assertIn("import is banned", _messages(src))

    def test_lambda_is_red(self) -> None:
        src = "def f():\n    return (lambda x: x)\n"
        self.assertIn("lambda", _messages(src))

    def test_getattr_is_red(self) -> None:
        src = "def f(obj):\n    return getattr(obj, 'x')\n"
        self.assertIn("getattr()", _messages(src))

    def test_type_is_check_is_red(self) -> None:
        src = "def f(x):\n    return type(x) is str\n"
        self.assertIn("type(x) is T", _messages(src))


class CheckerAllowsSubset(unittest.TestCase):
    def test_str_slice_on_constant_ok(self) -> None:
        src = """
        def f():
            return "hello world"[1:4]
        """
        self.assertEqual(_violations(src), [])

    def test_str_slice_on_name_ok(self) -> None:
        src = """
        def f(src):
            return src[1:4]
        """
        self.assertEqual(_violations(src), [])

    def test_len_minus_one_index_ok(self) -> None:
        src = """
        def f(xs):
            return xs[len(xs) - 1]
        """
        self.assertEqual(_violations(src), [])

    def test_index_loop_copy_ok(self) -> None:
        src = """
        def copy_range(xs, start, end):
            n = end - start
            out = [0] * n
            i = start
            j = 0
            while i < end:
                out[j] = xs[i]
                i = i + 1
                j = j + 1
            return out
        """
        self.assertEqual(_violations(src), [])

    def test_nested_def_without_closure_ok(self) -> None:
        src = """
        def outer(x):
            def inner(y):
                return y + 1
            return inner(x)
        """
        self.assertEqual(_violations(src), [])

    def test_try_except_ok(self) -> None:
        src = """
        def f():
            try:
                return 1
            except TypeError:
                return 0
        """
        self.assertEqual(_violations(src), [])

    def test_long_name_ok(self) -> None:
        src = """
        def f():
            this_is_a_very_long_identifier = 1
            return this_is_a_very_long_identifier
        """
        self.assertEqual(_violations(src), [])


class CompatHelpers(unittest.TestCase):
    def test_copy_range_last_rest(self) -> None:
        ns: dict[str, object] = {}
        path = compiler_subset.COMPILER_DIR / "compat.py"
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        copy_range = ns["copy_range"]
        last = ns["last"]
        rest = ns["rest"]
        xs = [10, 20, 30, 40]
        self.assertEqual(copy_range(xs, 1, 3), [20, 30])
        self.assertEqual(copy_range(xs, 3, 3), [])
        self.assertEqual(last(xs), 40)
        self.assertEqual(rest(xs), [20, 30, 40])
        compiler_subset.assert_compiler_subset()


class CompilerTreeIsInSubset(unittest.TestCase):
    def test_tree_passes(self) -> None:
        compiler_subset.assert_compiler_subset()

    def test_planted_negative_index_fails_tree_walk(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "bad.py").write_text(
                "def f(xs):\n    return xs[-1]\n", encoding="utf-8"
            )
            violations = compiler_subset.check_compiler_tree(root)
            self.assertTrue(any("negative index" in v.message for v in violations))


if __name__ == "__main__":
    unittest.main()
