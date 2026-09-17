"""Host T1–T4 result differential vs CPython (compiler_design.md H, J, T4).

Firmware ``_pyc_codegen_main`` must evaluate to the same result as CPython
``eval`` / ``exec``. Differentials never compare ``co_code`` (D1): no
CACHE. Constant folding (§11.3) rewrites int BinOp/UnaryOp and str Add.
Unary ``+True`` is excluded (CPython emits CALL_INTRINSIC_1 5; the device
only allows intrinsic 6). List displays emit ``BUILD_LIST n``, not
CPython's ``LIST_EXTEND``.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler codegen tests require Python 3.14")

from image_from_source import (
    _HOST_OP_BINARY_OP,
    _HOST_OP_CACHE,
    _HOST_OP_LOAD_CONST,
    _HOST_OP_LOAD_SMALL_INT,
    _HOST_OP_RETURN_VALUE,
    load_firmware_package_namespace,
)
from run_image_test import host_entry_result

PROGRAMS = pathlib.Path(__file__).resolve().parents[1] / "programs"


class Box:
    def __init__(self, v):
        self.v = v
        self.b = v

    def add(self, x):
        return self.v + x


def _f(*args):
    if len(args) == 0:
        return 7
    s = 0
    i = 0
    while i < len(args):
        s = s + args[i]
        i = i + 1
    return s


def _g(x):
    return x + 1


NUM_ENV = {
    "a": 2,
    "b": 3,
    "c": 4,
    "d": 5,
    "x": 10,
    "y": 3,
    "z": 2,
    "f": _f,
    "g": _g,
}

OBJ_ENV = {
    "a": Box(3),
    "xs": [10, 20, 30],
    "ys": [1, 2, 3],
    "s": "hi",
}


EVAL_LITERALS = [
    "1",
    "1 + 2",
    "0x1f",
    "1_000",
    "1 + 2 * 3",
    "(1 + 2) * 3",
    "1 - 2 - 3",
    "2 ** 3 ** 2",
    "-1",
    "-2 ** 2",
    "~1",
    "((((1))))",
    "(" * 40 + "1" + ")" * 40,
    "True and False",
    "None",
    "'hi'",
    "1.5",
    "256",
    "1 and 0",
    "0 or 5",
    "1 and 2",
    "1 or 2",
    "1 and 0 or 5",
    "not 0",
    "not 1",
    "not not 1",
    "1 < 2",
    "1 <= 1",
    "1 == 1",
    "1 != 2",
    "2 > 1",
    "2 >= 2",
    "1 < 2 < 3",
    "1 < 2 > 0",
    "1 == 1 != 0",
    "2 // 3",
    "7 % 4",
    "8 >> 2",
    "1 << 3",
    "5 & 3",
    "5 | 2",
    "5 ^ 1",
    "+1",
    "+ 2",
    "256 + 1",
    "True",
    "False",
    "(lambda x: x + 1)(6)",
    "(lambda: 7)()",
    'f"hello"',
    'f"a{1}b"',
    'f"{1}"',
    'f"{1!s}"',
    'f""',
]


EVAL_NAMES = [
    "a + b",
    "a + b * c + d",
    "a & b | c ^ d",
    "a << 1 >> 2",
    "x // y % z",
    "not a",
    "a and b or c",
    "a or b and c",
    "a and b and c",
    "a < b < c",
    "a == b != c",
    "a and (b and c)",
    "(a and b) and c",
    "not not a",
    "f()",
    "f(1)",
    "f(1, x)",
    "f(g(1), 2)",
    "f(1,)",
    "f(a < b, c)",
    "x",
    "abs(-3)",
    "[]",
    "[1, 2, 3]",
    "(1, 2)",
    "(1,)",
    "()",
    "{1: 2}",
    "{1, 2}",
]


EVAL_OBJECTS = [
    "a.b",
    "a.v",
    "xs[0]",
    "1 in ys",
    "0 not in ys",
    "a.add(2)",
    "s",
    "s[1:4]",
    "s[1:]",
    "s[:2]",
]


EXEC_CASES = [
    ("", None, {}),
    ("x = 1\n", None, {"x": 1}),
    ("x = 1 + 2\n", None, {"x": 3}),
    ("x = 1\ny = x + 2\n", None, {"x": 1, "y": 3}),
    ("1 + 2\n", None, {}),
    ("s = 0\ni = 0\nwhile i < 3:\n    s = s + i\n    i = i + 1\n", None, {"s": 3, "i": 3}),
    ("x = 1\nif x:\n    y = 2\nelse:\n    y = 0\n", None, {"x": 1, "y": 2}),
    ("x = 0\nif x:\n    y = 2\nelse:\n    y = 3\n", None, {"x": 0, "y": 3}),
    ("xs = [1, 2]\ns = 0\nfor i in xs:\n    s = s + i\n", None, {"s": 3}),
    ("x = 1\nx += 2\n", None, {"x": 3}),
    ("a, b = 1, 2\n", None, {"a": 1, "b": 2}),
    ("t = (1, 2)\n", None, {"t": (1, 2)}),
    ("d = {1: 2}\n", None, {"d": {1: 2}}),
    ("s = {1, 2}\n", None, {"s": {1, 2}}),
    ("def f():\n    return 1\nx = f()\n", None, {"x": 1}),
    ("def add(a, b):\n    return a + b\nx = add(2, 3)\n", None, {"x": 5}),
    (
        "def f(n):\n    s = 0\n    i = 0\n    while i < n:\n        s = s + i\n"
        "        i = i + 1\n    return s\nx = f(4)\n",
        None,
        {"x": 6},
    ),
    (
        "n = 3\ns = 0\ni = 0\nwhile i < n:\n    s = s + i\n    i = i + 1\n"
        "if s == 3:\n    s = s + 1\nelse:\n    s = 0\nxs = [1, 2]\n"
        "for x in xs:\n    s = s + x\ny = s\n",
        None,
        {"y": 7},
    ),
    (
        "try:\n    raise TypeError\nexcept TypeError:\n    x = 7\n",
        None,
        {"x": 7},
    ),
    (
        "x = 0\ntry:\n    x = 1\nexcept TypeError:\n    x = 2\nelse:\n    x = 3\n",
        None,
        {"x": 3},
    ),
    (
        "x = 0\ntry:\n    x = 1\nfinally:\n    x = x + 10\n",
        None,
        {"x": 11},
    ),
    (
        "xs = [x for x in [1, 2, 3]]\n",
        None,
        {"xs": [1, 2, 3]},
    ),
    (
        "x = (lambda n: n + 1)(6)\n",
        None,
        {"x": 7},
    ),
    (
        "assert 1\nx = 1\n",
        None,
        {"x": 1},
    ),
    (
        's = f"a{1}b"\n',
        None,
        {"s": "a1b"},
    ),
]


def firmware_codegen(src: str, mode: str = "eval"):
    g = load_firmware_package_namespace()
    g["_in_src"] = src
    g["_in_mode"] = mode
    return g["_pyc_codegen_main"]()


def firmware_eval(src: str, env: dict | None = None):
    co = firmware_codegen(src, "eval")
    if env is not None:
        co._globals.update(env)
    return co()


def emitted_opcodes(co) -> list[int]:
    pc = co._entry
    ops: list[int] = []
    for _ in range(1 << 12):
        word = co._ram.words.get(pc, 0)
        op = word & 0xFF
        ops.append(op)
        if op == _HOST_OP_RETURN_VALUE:
            return ops
        pc += 1
    raise AssertionError("no RETURN_VALUE in emitted words")


class TestCompilerCodegenCorpus(unittest.TestCase):
    def test_eval_literals_match_cpython(self) -> None:
        for src in EVAL_LITERALS:
            with self.subTest(src=src):
                self.assertEqual(firmware_eval(src), eval(src))

    def test_eval_names_match_cpython(self) -> None:
        env = dict(NUM_ENV)
        for src in EVAL_NAMES:
            with self.subTest(src=src):
                self.assertEqual(firmware_eval(src, env), eval(src, dict(env)))

    def test_eval_objects_match_cpython(self) -> None:
        env = dict(OBJ_ENV)
        env["c"] = 4
        for src in EVAL_OBJECTS:
            with self.subTest(src=src):
                self.assertEqual(firmware_eval(src, env), eval(src, dict(env)))

    def test_is_op_match_cpython(self) -> None:
        obj = []
        env = {"a": obj, "b": obj, "c": []}
        for src in ("a is b", "a is not c", "a is c"):
            with self.subTest(src=src):
                self.assertEqual(firmware_eval(src, env), eval(src, dict(env)))

    def test_exec_assigns_match_cpython(self) -> None:
        for src, result, want in EXEC_CASES:
            with self.subTest(src=src):
                co = firmware_codegen(src, "exec")
                got = co()
                self.assertEqual(got, result)
                g = {}
                exec(src, g)
                for name, value in want.items():
                    self.assertEqual(co._globals[name], value)
                    self.assertEqual(g[name], value)

    def test_exec_attr_store(self) -> None:
        box = Box(0)
        co = firmware_codegen("a.b = 1\n", "exec")
        co._globals["a"] = box
        self.assertIsNone(co())
        self.assertEqual(box.b, 1)

    def test_exec_subscr_store(self) -> None:
        xs = [0, 0]
        co = firmware_codegen("xs[0] = 1\n", "exec")
        co._globals["xs"] = xs
        self.assertIsNone(co())
        self.assertEqual(xs[0], 1)

    def test_constant_folding_on_one_plus_two(self) -> None:
        # Rewrites the former D2 pin: 1+2 is now LOAD_SMALL_INT 3 (no BINARY_OP).
        co = firmware_codegen("1 + 2", "eval")
        ops = emitted_opcodes(co)
        self.assertNotIn(_HOST_OP_CACHE, ops)
        self.assertNotIn(_HOST_OP_BINARY_OP, ops)
        self.assertEqual(ops.count(_HOST_OP_LOAD_SMALL_INT), 1)
        self.assertEqual(co(), 3)

    def test_constant_folding_nested_and_names_untouched(self) -> None:
        co = firmware_codegen("1 + 2 * 3", "eval")
        ops = emitted_opcodes(co)
        self.assertNotIn(_HOST_OP_BINARY_OP, ops)
        self.assertEqual(co(), 7)
        co2 = firmware_codegen("1 + x", "eval")
        ops2 = emitted_opcodes(co2)
        self.assertIn(_HOST_OP_BINARY_OP, ops2)
        co2._globals["x"] = 10
        self.assertEqual(co2(), 11)

    def test_constant_folding_str_add(self) -> None:
        co = firmware_codegen("'ab' + 'cd'", "eval")
        ops = emitted_opcodes(co)
        self.assertNotIn(_HOST_OP_BINARY_OP, ops)
        self.assertIn(_HOST_OP_LOAD_CONST, ops)
        self.assertEqual(co(), "abcd")

    def test_def_compiles_and_returns(self) -> None:
        co = firmware_codegen("def f():\n    return 1\n", "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["f"](), 1)

    def test_closure_load_enclosing_local(self) -> None:
        src = (
            "def outer():\n"
            "    x = 1\n"
            "    def inner():\n"
            "        return x\n"
            "    return inner()\n"
            "z = outer()\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 1)

    def test_closure_enclosing_param_and_store(self) -> None:
        src = (
            "def outer(x):\n"
            "    def inner():\n"
            "        return x\n"
            "    x = x + 4\n"
            "    return inner()\n"
            "z = outer(3)\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 7)

    def test_closure_passthrough_mid(self) -> None:
        src = (
            "def outer():\n"
            "    x = 3\n"
            "    def mid():\n"
            "        def inner():\n"
            "            return x\n"
            "        return inner()\n"
            "    return mid()\n"
            "z = outer()\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 3)

    def test_for_break_continue(self) -> None:
        src = (
            "s = 0\n"
            "for i in [1, 2, 3, 4]:\n"
            "    if i == 2:\n"
            "        continue\n"
            "    if i == 4:\n"
            "        break\n"
            "    s = s + i\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        g = {}
        exec(src, g)
        self.assertEqual(co._globals["s"], g["s"])
        self.assertEqual(co._globals["s"], 4)

    def test_del_fast(self) -> None:
        src = "def f():\n    x = 1\n    y = 2\n    del x\n    return y\nz = f()\n"
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 2)

    def test_identity_decorator(self) -> None:
        src = (
            "def d(fn):\n"
            "    return fn\n"
            "@d\n"
            "def f():\n"
            "    return 7\n"
            "z = f()\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 7)

    def test_assert_message_raises(self) -> None:
        src = "assert 0, 'nope'\n"
        co = firmware_codegen(src, "exec")
        with self.assertRaises(AssertionError) as cm:
            co()
        self.assertEqual(str(cm.exception), "nope")

    def test_fstring_conversion_repr(self) -> None:
        self.assertEqual(firmware_eval('f"{1!r}"'), "1")
        self.assertEqual(firmware_eval('f"{1!s}"'), "1")

    def test_lambda_closure(self) -> None:
        src = (
            "def outer(x):\n"
            "    return (lambda: x)\n"
            "z = outer(7)()\n"
        )
        co = firmware_codegen(src, "exec")
        self.assertIsNone(co())
        self.assertEqual(co._globals["z"], 7)

    def test_empty_suite_does_not_emit_a_negative_jump(self) -> None:
        for src in (
            "x = 1\nif x:\n    pass\ny = 2\n",
            "x = 0\nif x:\n    pass\ny = 2\n",
            "s = 0\nfor i in [1, 2]:\n    if i:\n        pass\n    s = s + i\n",
            "def f(a):\n    if a:\n        pass\n    return 3\nz = f(1)\n",
        ):
            with self.subTest(src=src):
                co = firmware_codegen(src, "exec")
                co()
                g = {}
                exec(src, g)
                for name in ("x", "y", "s", "z"):
                    if name in g:
                        self.assertEqual(co._globals[name], g[name])

    def test_no_emitted_word_has_a_negative_oparg(self) -> None:
        src = (
            "x = 1\n"
            "if x:\n"
            "    pass\n"
            "for i in [1, 2]:\n"
            "    if i:\n"
            "        pass\n"
            "    else:\n"
            "        x = i\n"
        )
        co = firmware_codegen(src, "exec")
        pc = co._entry
        for _ in range(1 << 12):
            word = co._ram.words.get(pc, 0)
            self.assertGreaterEqual(word, 0)
            self.assertEqual(word >> 40, 0)
            if word & 0xFF == _HOST_OP_RETURN_VALUE:
                break
            pc += 1

    def test_int_and_float_constants_do_not_share_a_pool_slot(self) -> None:
        for src, want in (
            ("x = 1000\ny = 1000.0\n", {"x": int, "y": float}),
            ("x = 1000.0\ny = 1000\n", {"x": float, "y": int}),
            ("x = 0.0\ny = 0\n", {"x": float, "y": int}),
        ):
            with self.subTest(src=src):
                co = firmware_codegen(src, "exec")
                co()
                g = {}
                exec(src, g)
                for name, typ in want.items():
                    self.assertIs(type(co._globals[name]), typ)
                    self.assertIs(type(g[name]), typ)

    def test_nested_code_object_is_never_a_dedup_comparison_operand(self) -> None:
        src = (
            "def f():\n"
            "    return 1\n"
            "x = 'hello'\n"
            "y = 1000\n"
            "z = 1.5\n"
        )
        co = firmware_codegen(src, "exec")
        co()
        h = {}
        exec(src, h)
        for name in ("x", "y", "z"):
            self.assertEqual(co._globals[name], h[name])
            self.assertIs(type(co._globals[name]), type(h[name]))
        self.assertEqual(co._globals["f"](), 1)

    def test_unary_plus_true_is_not_in_differential(self) -> None:
        # Pin the known deviation: firmware leaves True, CPython yields 1.
        self.assertEqual(firmware_eval("+True"), True)
        self.assertEqual(eval("+True"), 1)

    def test_img_codegen_t1_expr_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_codegen_t1_expr.py", "managed_entry"),
            3,
        )
        self.assertEqual(firmware_eval("1 + 2"), 3)

    def test_eval_listcomp_match_cpython(self) -> None:
        env = {"xs": [1, 2, 3]}
        src = "[x for x in xs]"
        self.assertEqual(firmware_eval(src, env), eval(src, dict(env)))

    def test_eval_str_slice_match_cpython(self) -> None:
        env = {"s": "abcdef"}
        for src in ("s[1:4]", "s[1:]", "s[:2]", "s[:]"):
            with self.subTest(src=src):
                self.assertEqual(firmware_eval(src, env), eval(src, dict(env)))


if __name__ == "__main__":
    unittest.main()
