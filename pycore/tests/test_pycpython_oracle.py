"""Host oracle: vendored PyCPython matches CPython 3.14 compile() on T1 snippets."""

from __future__ import annotations

import sys
import types
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("PyCPython oracle tests require Python 3.14")

from pathlib import Path

_VENDOR_COMPILE = (
    Path(__file__).resolve().parents[2]
    / "vendor"
    / "pycpython"
    / "pycpython"
    / "compile.py"
)
if not _VENDOR_COMPILE.is_file():
    raise unittest.SkipTest(
        "PyCPython submodule not initialized (git submodule update --init)"
    )

from pycpython_vendor import ensure_importable


# Match vendor/pycpython/tests/check_codegen.py: dont_inherit=True so the
# running module's __future__ flags are not mixed into the oracle compile().
SNIPPETS = (
    ("x = 1 + 2\n", "exec"),
    ("def f(a):\n    return a * 3\n", "exec"),
    ("1 + 2 * 3", "eval"),
)

CODE_ATTRS = (
    "co_argcount",
    "co_posonlyargcount",
    "co_kwonlyargcount",
    "co_nlocals",
    "co_stacksize",
    "co_flags",
    "co_code",
    "co_names",
    "co_varnames",
    "co_freevars",
    "co_cellvars",
    "co_exceptiontable",
)


def _diff_code(ours: types.CodeType, ref: types.CodeType, path: str, out: list) -> None:
    for attr in CODE_ATTRS:
        va, vb = getattr(ours, attr), getattr(ref, attr)
        if va != vb:
            out.append((path, attr, va, vb))
    if len(ours.co_consts) != len(ref.co_consts):
        out.append((path, "co_consts(len)", len(ours.co_consts), len(ref.co_consts)))
        return
    for i, (ca, cb) in enumerate(zip(ours.co_consts, ref.co_consts)):
        if isinstance(ca, types.CodeType) and isinstance(cb, types.CodeType):
            _diff_code(ca, cb, path + "/" + cb.co_name, out)
        elif isinstance(ca, types.CodeType) or isinstance(cb, types.CodeType):
            out.append((path, f"co_consts[{i}]", ca, cb))
        elif ca != cb:
            out.append((path, f"co_consts[{i}]", ca, cb))


class TestPyCPythonOracle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ensure_importable()
        from pycpython.compile import compile_source

        cls.compile_source = staticmethod(compile_source)

    def test_submodule_layout(self):
        root = ensure_importable()
        self.assertTrue((root / "pycpython" / "compile.py").is_file())
        self.assertTrue((root / "STATUS.md").is_file())

    def test_tier1_matches_cpython(self):
        for source, mode in SNIPPETS:
            with self.subTest(source=source, mode=mode):
                ours = self.compile_source(source, "<oracle>", mode)
                ref = compile(source, "<oracle>", mode, 0, True)
                diffs = []
                _diff_code(ours, ref, "<oracle>", diffs)
                self.assertEqual(diffs, [])

    def test_constant_fold_matches_cpython(self):
        source = "x = 1 + 2\nprint(x)\n"
        ours = self.compile_source(source, "t.py", "exec")
        ref = compile(source, "t.py", "exec", 0, True)
        self.assertEqual(ours.co_code, ref.co_code)
        self.assertEqual(ours.co_names, ref.co_names)
        self.assertIn("x", ours.co_names)
        self.assertIn("print", ours.co_names)


if __name__ == "__main__":
    unittest.main()
