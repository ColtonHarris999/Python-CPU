"""Host locals-vs-globals corpus (compiler_design.md G).

Firmware ``_pyc_symtab`` locals must match CPython ``co_varnames`` for
each function. Closures raise
``SyntaxError("closures are not supported on this target")``.
"""

from __future__ import annotations

import pathlib
import sys
import types
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler symtab tests require Python 3.14")

from image_from_source import load_firmware_package_namespace
from run_image_test import host_entry_result

PROGRAMS = pathlib.Path(__file__).resolve().parents[1] / "programs"

CLOSURE_MSG = "closures are not supported on this target"

SYMTAB_LOCALS_SRC = """\
x = 1
def f(a, b):
    y = a + b
    return y + x
"""

SYMTAB_CORPUS = [
    "",
    "x = 1\n",
    "x = 1\ny = 2\n",
    "def f():\n    return 1\n",
    "def f(a):\n    return a\n",
    "def f(a, b):\n    return a + b\n",
    "def f(a, b):\n    x = a + b\n    return x\n",
    SYMTAB_LOCALS_SRC,
    "def f():\n    global x\n    x = 1\n    return x\n",
    "def f():\n    y = 1\n    global x\n    x = y\n    return x\n",
    "def outer(x):\n    def inner(y):\n        return y\n    return inner\n",
    "def outer():\n    def inner():\n        return 1\n    return inner\n",
    "x = 1\ndef f():\n    return x\n",
    "def f(a):\n    a.b = 1\n    return a\n",
    "def f(a):\n    a[0] = 1\n    return a\n",
    "def f(): return 1\n",
    "def f(a,):\n    x = a\n    return x\n",
]


def firmware_symtab(src: str, mode: str = "exec") -> dict:
    g = load_firmware_package_namespace()
    g["_in_src"] = src
    g["_in_mode"] = mode
    g["_pyc_lex"](src)
    root = g["_pyc_parse"](mode)
    g["_pyc_symtab"](root)
    return g


def firmware_function_scopes(g: dict) -> list[tuple[str, tuple[str, ...], int, int]]:
    out = []
    i = 0
    while i < g["sc_n"]:
        if g["sc_kind"][i] == 1:
            nloc = g["sc_nlocals"][i]
            names = g["sc_varnames"][i]
            varnames = tuple(names[j] for j in range(nloc))
            nid = g["sc_node"][i]
            fname = g["nd_obj"][nid]
            out.append((fname, varnames, nloc, g["sc_argcount"][i]))
        i += 1
    return out


def cpython_function_scopes(src: str, mode: str = "exec") -> list[tuple[str, tuple[str, ...], int, int]]:
    co = compile(src, "<s>", mode)
    out = []

    def walk(code: types.CodeType) -> None:
        for const in code.co_consts:
            if isinstance(const, types.CodeType):
                out.append(
                    (
                        const.co_name,
                        const.co_varnames,
                        const.co_nlocals,
                        const.co_argcount,
                    )
                )
                walk(const)

    walk(co)
    return out


class TestCompilerSymtabCorpus(unittest.TestCase):
    def test_locals_match_cpython_varnames(self) -> None:
        for src in SYMTAB_CORPUS:
            with self.subTest(src=src):
                g = firmware_symtab(src, "exec")
                got = firmware_function_scopes(g)
                want = cpython_function_scopes(src, "exec")
                self.assertEqual(got, want)
                self.assertEqual(g["sc_kind"][0], 0)
                self.assertEqual(g["sc_nlocals"][0], 0)

    def test_eval_names_are_global(self) -> None:
        g = firmware_symtab("a + b", "eval")
        self.assertEqual(g["sc_n"], 1)
        self.assertEqual(g["sc_kind"][0], 0)
        self.assertEqual(g["sc_nlocals"][0], 0)
        self.assertEqual(firmware_function_scopes(g), [])

    def test_closure_load_enclosing_local(self) -> None:
        src = "def outer():\n    x = 1\n    def inner():\n        return x\n    return inner\n"
        with self.assertRaises(SyntaxError) as cm:
            firmware_symtab(src, "exec")
        self.assertEqual(str(cm.exception), CLOSURE_MSG)

    def test_closure_enclosing_param(self) -> None:
        src = "def outer(x):\n    def inner():\n        return x\n    return inner\n"
        with self.assertRaises(SyntaxError) as cm:
            firmware_symtab(src, "exec")
        self.assertEqual(str(cm.exception), CLOSURE_MSG)

    def test_nested_def_without_closure_ok(self) -> None:
        src = "def outer(x):\n    def inner(y):\n        return y\n    return inner\n"
        g = firmware_symtab(src, "exec")
        got = firmware_function_scopes(g)
        self.assertEqual(got[0][0], "outer")
        self.assertEqual(got[0][1], ("x", "inner"))
        self.assertEqual(got[1][0], "inner")
        self.assertEqual(got[1][1], ("y",))

    def test_global_decl_keeps_name_out_of_locals(self) -> None:
        src = "def f():\n    global x\n    x = 1\n    return x\n"
        g = firmware_symtab(src, "exec")
        self.assertEqual(firmware_function_scopes(g)[0][1], ())

    def test_sixty_four_locals_ok(self) -> None:
        assigns = "\n".join(f"    x{i} = {i}" for i in range(64))
        src = f"def f():\n{assigns}\n    return x0\n"
        g = firmware_symtab(src, "exec")
        names = firmware_function_scopes(g)[0][1]
        self.assertEqual(len(names), 64)
        self.assertEqual(names[0], "x0")
        self.assertEqual(names[63], "x63")

    def test_too_many_locals_is_syntax_error(self) -> None:
        assigns = "\n".join(f"    x{i} = {i}" for i in range(241))
        src = f"def f():\n{assigns}\n    return x0\n"
        with self.assertRaises(SyntaxError) as cm:
            firmware_symtab(src, "exec")
        self.assertIn("too many locals", str(cm.exception))

    def test_assigned_before_global(self) -> None:
        src = "def f():\n    x = 1\n    global x\n    return x\n"
        with self.assertRaises(SyntaxError):
            firmware_symtab(src, "exec")

    def test_img_symtab_locals_host_golden(self) -> None:
        g = firmware_symtab(SYMTAB_LOCALS_SRC, "exec")
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_symtab_locals.py", "managed_entry"),
            g["_pyc_symtab_checksum"](),
        )

    def test_img_symtab_closure_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_symtab_closure.py", "managed_entry"),
            1,
        )


if __name__ == "__main__":
    unittest.main()
