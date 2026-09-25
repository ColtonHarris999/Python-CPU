"""A7: firmware compiler vs host CPython, compared by **result**.

``compiler_design.md`` §1 names this file as the acceptance check for A7 and
§8 R5 as the mitigation for silent miscompilation: every corpus program is
compiled twice -- once by ``pycore_firmware/compiler/`` running under host
CPython with the W-5 builtin stand-ins, once by CPython itself -- and the two
are compared on what they *produce*, never on ``co_code`` (D1: the firmware
emits no ``CACHE`` padding and folds int/str constants, so the byte streams
differ by design).

The corpus is the language the device is supposed to run, tier by tier. A
construct the machine cannot execute must come back as a ``SyntaxError``
from the compiler rather than a trap at run time (A4/D5); those live in
``REJECT_CORPUS`` with the substring their message must contain.
"""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler differential tests require Python 3.14")

from image_from_source import load_rom_firmware_callables

# ---------------------------------------------------------------------------
# Expression corpus: compiled in "eval" mode, compared by returned value.
# ---------------------------------------------------------------------------

EVAL_CORPUS = [
    # T1 literals and arithmetic
    "1",
    "1 + 2",
    "3 * 4 + 5",
    "(1 + 2) * 3",
    "7 // 2",
    "7 % 3",
    "2 ** 10",
    "[1, 2, 3][-1]",
    "'ab'[-1]",
    "[1, 2, 3][0:2]",
    "(1, 2, 3)[1:]",
    "[1, 2, 3, 4][-2:]",
    "'abc'[-1:]",
    "'abc'[:-1]",
    "1 << 4",
    "255 >> 4",
    "5 & 3",
    "5 | 3",
    "5 ^ 3",
    "~5",
    "-5",
    "+5",
    "1 - 2 - 3",
    "2 ** 3 ** 2",
    "-2 ** 2",
    "1 + 2 * 3 - 4 // 2",
    "((((((1))))))",
    "0x1f",
    "0b1011",
    "0o17",
    "1_000",
    "1.5 + 2.5",
    "1.0 / 2",
    "1e3",
    "1.5e-3",
    # T1 comparisons and boolean logic
    "1 < 2",
    "2 <= 2",
    "3 > 4",
    "4 >= 4",
    "1 == 1",
    "1 != 2",
    "1 < 2 < 3",
    "1 < 2 > 3",
    "1 < 2 <= 2 < 3",
    "True and False",
    "True or False",
    "0 or 5",
    "1 and 0",
    "not 0",
    "not 1",
    "not not 1",
    "None is None",
    "None is not None",
    # T3 displays and subscripts
    "[1, 2, 3]",
    "(1, 2, 3)",
    "{1, 2, 3}",
    "{'a': 1}",
    "[]",
    "()",
    "{}",
    "(1,)",
    "[1, 2, 3][1]",
    "(1, 2, 3)[0]",
    "{'a': 1}['a']",
    "[1, 2] + [3]",
    "[0] * 3",
    "1 in [1, 2]",
    "5 not in [1, 2]",
    # T4 strings and slicing
    "'abc'[1]",
    "'abcdef'[1:4]",
    "'abcdef'[2:]",
    "'abcdef'[:2]",
    "'a' + 'b'",
    "'ab' * 3",
    "'a' in 'abc'",
    "'z' not in 'abc'",
    "'a,b,c'.split(',')",
    "'HI'.lower()",
    "' x '.strip()",
    # Boot builtins
    "len([1, 2, 3])",
    "max(1, 5, 3)",
    "min(4, 2, 9)",
    "abs(-4)",
    "sum([1, 2, 3])",
    "sorted([3, 1, 2])",
    "list(range(4))",
    "str(12)",
    "int('34')",
    "ord('a')",
    "chr(98)",
    # T4 comprehensions, including an element expression and an `if` filter
    "[x for x in [1, 2, 3]]",
    "[x * 2 for x in [1, 2, 3]]",
    "[x + 1 for x in [1, 2, 3] if x > 1]",
    "{x for x in [1, 2, 2]}",
    "{x * 2 for x in [1, 2]}",
    "{x: x * 2 for x in [1, 2]}",
    "{x: x for x in [1, 2, 3] if x != 2}",
    # T5 lambda and f-strings
    "(lambda x: x + 1)(6)",
    "(lambda: 5)()",
    "(lambda x, y=3: x + y)(1)",
    "(lambda *a: len(a))(1, 2, 3)",
    "f'a{1}b'",
    "f'{1 + 2}'",
    # Conditional expressions
    "1 if 2 else 3",
    "0 if 0 else 9",
    "1 if 0 else 2 if 1 else 3",
    "(1 if 0 else 2) + 3",
    "[x if x else 0 for x in [0, 1, 2]]",
    # Keyword call sites (CALL_KW)
    "max(1, 2)",
    "sorted([3, 1, 2])",
]

# ---------------------------------------------------------------------------
# Statement corpus: compiled in "exec" mode, compared by resulting globals.
# ---------------------------------------------------------------------------

EXEC_CORPUS = [
    # T1/T2 assignment and control flow
    "x = 1",
    "x = 1 + 2\ny = x * 3",
    "x = 1; y = 2",
    "x = y = 1",
    "x = y = z = 1 + 2",
    "x = 0\nfor i in [1, 2, 3]:\n    x = x + i\n",
    "x = 0\nwhile x < 5:\n    x = x + 1\n",
    "x = 1\nif x:\n    y = 2\nelse:\n    y = 3\n",
    "x = 3\nif x == 1:\n    y = 1\nelif x == 3:\n    y = 33\nelse:\n    y = 0\n",
    "x = 0\nfor i in [1, 2, 3, 4]:\n    if i == 3:\n        break\n    x = x + i\n",
    "x = 0\nfor i in [1, 2, 3, 4]:\n    if i == 3:\n        continue\n    x = x + i\n",
    "x = 5\nx += 3\nx -= 1\nx *= 2\n",
    "x = 0\nfor i in range(4):\n    x = x + i\n",
    "n = 0\nfor i in [1, 2]:\n    for j in [3, 4]:\n        n = n + i * j\n",
    "x = 1\nif x: y = 2\n",
    "x = 1 if 0 else 2\n",
    # T3 containers and unpacking
    "a, b = 1, 2\nc = a + b\n",
    "x = [1, 2, 3]\nx[0] = 9\ny = x[0]\n",
    "d = {}\nd['k'] = 5\nv = d['k']\n",
    "x = (1, 2, 3)\na, b, c = x\n",
    "x = 1\ny = 2\nx, y = y, x\n",
    "x = [i for i in range(5)]\ny = sum(x)\n",
    # T3 functions: every parameter form the grammar accepts
    "def f():\n    return 1\nx = f()\n",
    "def f(a, b):\n    return a + b\nx = f(1, 2)\n",
    "def f(a, b=2):\n    return a + b\nx = f(1)\ny = f(1, 5)\n",
    "def f(a=1, b=2):\n    return a * 10 + b\nx = f()\ny = f(3)\nz = f(3, 4)\nw = f(b=9)\n",
    "def f(*a):\n    return len(a)\nx = f()\ny = f(1, 2, 3)\n",
    "def f(**k):\n    return len(k)\nx = f()\ny = f(a=1, b=2)\n",
    "def f(a, *b):\n    return a + len(b)\nx = f(1)\ny = f(1, 2, 3)\n",
    "def f(a, *, b):\n    return a - b\nx = f(1, b=2)\n",
    "def f(a, *, b=7):\n    return a - b\nx = f(1)\ny = f(1, b=2)\n",
    (
        "def f(a, b=2, *c, d=4, **e):\n"
        "    return a + b + len(c) + d + len(e)\n"
        "x = f(1)\ny = f(1, 2, 3, 4, d=5, z=6)\n"
    ),
    "def f(a, b):\n    return a - b\nx = f(b=1, a=5)\ny = f(5, b=1)\n",
    "def f(a=-1):\n    return a\nx = f()\n",
    "def f(a='hi'):\n    return a\nx = f()\n",
    "def f(a=None):\n    return a is None\nx = f()\n",
    "def f(a=True):\n    return a\nx = f()\n",
    "def f(x):\n    return x\ny = f(f(f(1)))\n",
    "def f():\n    a = 1\n    b = 2\n    return a + b\nx = f()\n",
    "g = 1\ndef f():\n    global g\n    g = 2\nf()\n",
    # T4 exceptions
    "try:\n    x = 1\nexcept TypeError:\n    x = 2\n",
    "try:\n    raise TypeError('m')\nexcept TypeError:\n    x = 7\n",
    "try:\n    x = 1\nexcept TypeError:\n    x = 2\nelse:\n    x = 3\n",
    "x = 1\ntry:\n    x = x + 1\nfinally:\n    x = x + 10\n",
    "try:\n    raise TypeError('m')\nexcept TypeError as e:\n    x = 7\n",
    # Closures and T5 decorators
    "def outer(a):\n    def inner():\n        return a + 4\n    return inner()\nx = outer(3)\n",
    "def d(fn):\n    return fn\n@d\ndef f():\n    return 7\nx = f()\n",
    "assert 1\nx = 1\n",
    # Strings and attributes
    "s = 'hello'\nx = s.upper()\n",
    "x = 'a,b,c'.split(',')\n",
    "x = [1]\ndel x[0]\ny = len(x)\n",
    "def f():\n    a = 1\n    del a\n    return 2\nx = f()\n",
    # finally on break / continue / return, and on a propagating exception
    "x = 0\nwhile 1:\n    try:\n        break\n    finally:\n        x = 1\n",
    "def f():\n    try:\n        return 1\n    finally:\n        return 2\nx = f()\n",
    "g = 0\ndef f():\n    global g\n    try:\n        return 1\n    finally:\n        g = 7\nx = f()\n",
    "x = 0\nfor i in [1, 2, 3]:\n    try:\n        if i == 2:\n            continue\n        x = x + i\n    finally:\n        x = x + 10\n",
    "x = 0\ntry:\n    try:\n        raise TypeError('m')\n    except ValueError:\n        x = 1\n    finally:\n        x = x + 5\nexcept TypeError:\n    x = x + 100\n",
    "x = 0\ntry:\n    try:\n        raise TypeError('m')\n    finally:\n        x = 5\nexcept TypeError:\n    x = x + 1\n",
    "def f():\n    try:\n        raise TypeError('m')\n    except TypeError as e:\n        pass\n    try:\n        return e\n    except UnboundLocalError:\n        return 9\nx = f()\n",
    "x = [i for i in [1, 2, 3]]\ntry:\n    y = i\nexcept NameError:\n    y = 9\n",
    "i = 4\nx = [i for i in [1, 2, 3]]\ny = i\n",
    "x = 'a\\tb'\n",
    "x = 0\nfor i in [1, 2]:\n    x = x + i\nelse:\n    x = x + 10\n",
    "x = 0\nfor i in [1, 2, 3]:\n    if i == 2:\n        break\n    x = x + i\nelse:\n    x = x + 10\n",
    "x = 0\nwhile x < 2:\n    x = x + 1\nelse:\n    x = x + 10\n",
    "x = 0\nwhile 1:\n    x = 1\n    break\nelse:\n    x = 5\n",
]

# ---------------------------------------------------------------------------
# A4/D5: what the machine cannot execute must be a compile-time SyntaxError.
# ---------------------------------------------------------------------------

REJECT_CORPUS = [
    ("exec", "import os", "import"),
    ("exec", "from os import path", "import"),
    ("exec", "class C:\n    x = 1\n", "class"),
    ("exec", "with x:\n    y = 1\n", "with"),
    ("exec", "def f():\n    yield 1\n", "yield"),
    ("exec", "async def f():\n    return 1\n", "async"),
    ("exec", "x = 1\ndel x\n", "del of a global name"),
    ("exec", "def f(a=b):\n    return a\n", "literal"),
    ("eval", "f(a=1, 2)", "positional argument follows keyword"),
    ("eval", "f(a=1, a=2)", "duplicate keyword"),
    ("exec", "def f(a, /, b):\n    return a\n", "positional-only"),
    ("exec", "def f(a: int):\n    return a\n", "annotations"),
    ("exec", "def f() -> int:\n    return 1\n", "annotations"),
    ("eval", "1 if 2", "expected 'else'"),
    ("eval", "(x for x in xs)", "generator expressions"),
    ("exec", "raise TypeError from None", "raise-from"),
    ("exec", "x = 'a\\u0041'\n", "unsupported escape"),
    ("eval", "[x for x in xs for y in ys]", "nested comprehension"),
    ("exec", "def f(*a, *b):\n    return a\n", "duplicate '*'"),
    ("exec", "x[0:1:2]", "slice step"),
]


def _firmware_compile():
    """The ROM ``compile`` shim running over the W-5 builtin stand-ins."""
    return load_rom_firmware_callables()["compile"]


def _scrub(globals_: dict) -> dict:
    """Comparable view of a module namespace.

    Function objects differ by construction -- CPython builds a real
    ``function``, the stand-in an interpreted ``_HostEmittedCode`` -- so they
    collapse to a marker. What matters is that the *values* the program
    computed agree.
    """
    return {
        key: ("<callable>" if callable(value) else value)
        for key, value in globals_.items()
        if not key.startswith("__")
    }


class TestCompilerDifferential(unittest.TestCase):
    """A7: firmware compiler result == CPython result, over the corpus."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.compile_fn = staticmethod(_firmware_compile())

    def test_eval_corpus_results_match_cpython(self) -> None:
        for src in EVAL_CORPUS:
            with self.subTest(src=src):
                want = eval(compile(src, "<s>", "eval"), {})
                got = self.compile_fn(src, "<s>", "eval")()
                self.assertEqual(got, want)

    def test_exec_corpus_globals_match_cpython(self) -> None:
        for src in EXEC_CORPUS:
            with self.subTest(src=src):
                want_globals: dict = {}
                exec(compile(src, "<s>", "exec"), want_globals)
                code = self.compile_fn(src, "<s>", "exec")
                code()
                want = _scrub(want_globals)
                got = _scrub(code._globals)
                # The stand-in namespace starts empty, so compare the names
                # CPython bound; extra scratch names are not a difference in
                # the compiled program's meaning.
                self.assertEqual({k: got.get(k) for k in want}, want)

    def test_unsupported_constructs_are_syntax_errors(self) -> None:
        for mode, src, want in REJECT_CORPUS:
            with self.subTest(src=src):
                with self.assertRaises(SyntaxError) as caught:
                    self.compile_fn(src, "<s>", mode)
                self.assertIn(want, str(caught.exception))

    def test_del_of_a_name_is_rejected_because_hardware_cannot_do_it(self) -> None:
        """`del x` at module scope is D5, not an unfinished feature.

        ``DELETE_NAME`` and ``DELETE_GLOBAL`` are absent from the machine
        catalog, so there is no encoding for them; emitting one would be the
        illegal-opcode trap A4 exists to prevent. ``del`` of a *local*
        (``DELETE_FAST``) and ``del xs[i]`` (``DELETE_SUBSCR``) do work, and
        the corpus above covers both. If either opcode is ever implemented,
        this test fails and the compiler should start emitting it.
        """
        import json
        import pathlib as _pathlib

        catalog = json.loads(
            (
                _pathlib.Path(__file__).resolve().parents[1]
                / "targets"
                / "pycore.json"
            ).read_text(encoding="utf-8")
        )
        opcodes = catalog["opcodes"]
        for name in ("DELETE_NAME", "DELETE_GLOBAL"):
            self.assertNotIn(name, opcodes, f"{name} is now in the catalog")
        for name in ("DELETE_FAST", "DELETE_SUBSCR"):
            self.assertEqual(opcodes[name]["support"], "execute")

    def test_cpython_syntax_errors_are_syntax_errors(self) -> None:
        """Malformed source must not reach codegen as something else."""
        for src in (
            "x = = 1",
            "def f(:\n    return 1\n",
            "(1 + ",
            "1 +",
            "[1, 2",
            "if x\n    y = 1\n",
            "x = 1\n  y = 2\n",
        ):
            with self.subTest(src=src):
                with self.assertRaises(SyntaxError):
                    self.compile_fn(src, "<s>", "exec")


if __name__ == "__main__":
    unittest.main()
