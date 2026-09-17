"""Host AST shape differential vs CPython ``ast.parse`` (compiler_design.md F)."""

from __future__ import annotations

import ast
import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler parser tests require Python 3.14")

from image_from_source import load_firmware_package_namespace, _host_exec_globals
from run_image_test import host_entry_result

PROGRAMS = pathlib.Path(__file__).resolve().parents[1] / "programs"


PARSER_EVAL_CORPUS = [
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
    "not a",
    "not a in b",
    "a and b or c",
    "a or b and c",
    "a and b and c",
    "a < b < c",
    "a == b != c",
    "a is b",
    "a is not b",
    "a in b",
    "a not in b",
    "a.b",
    "a.b.c",
    "a[0]",
    "a.b[0]",
    "f()",
    "f(1)",
    "f(1, x)",
    "f(g(1), 2)",
    "f(1,)",
    "((((1))))",
    "(" * 40 + "1" + ")" * 40,
    "a + b * c + d",
    "a & b | c ^ d",
    "a << 1 >> 2",
    "x // y % z",
    "True and False",
    "None",
    "'hi'",
    "x",
    "f(a < b, c)",
    "a and (b and c)",
    "(a and b) and c",
    "not not a",
    "+a",
    "a[b][c]",
    "f()()",
    "a.b(c)",
    "[]",
    "[1]",
    "[1, 2]",
    "[1, 2,]",
    "()",
    "(1,)",
    "(1, 2)",
    "{}",
    "{1: 2}",
    "{1: 2, 3: 4}",
    "{1}",
    "{1, 2}",
    "[a, b]",
    "(a, b)",
    "a[1:4]",
    "a[1:]",
    "a[:4]",
    "a[:]",
    "[x for x in xs]",
    "{x for x in xs}",
    "{x: x for x in xs}",
    "lambda x: x + 1",
    "lambda: 1",
    "lambda x, y: x + y",
    'f"hello"',
    'f"a{x}b"',
    'f"{x}"',
    'f"{x!s}"',
    'f"{x!r}"',
    'f"a{1}b"',
    'f""',
]


PARSER_EXEC_CORPUS = [
    "",
    "\n",
    "x = 1\n",
    "x = 1 + 2\n",
    "a.b = 1\n",
    "a[0] = 1\n",
    "return a + b\n",
    "return\n",
    "1 + 2\n",
    "x = 1\ny = 2\n",
    "f(1)\n",
    "def f():\n    return 1\n",
    "def f(a, b):\n    return a + b\n",
    "def f(): return 1\n",
    "def f(a,):\n    x = a\n    return x\n",
    "global x\n",
    "global x, y\n",
    "def f():\n    global x\n    x = 1\n    return x\n",
    "def outer(x):\n    def inner(y):\n        return y\n    return inner\n",
    "x = 1\ndef f(a):\n    return a + x\ny = 2\n",
    "if x:\n    y = 1\n",
    "if x:\n    y = 1\nelse:\n    y = 2\n",
    "if x:\n    y = 1\nelif z:\n    y = 2\nelse:\n    y = 3\n",
    "while x:\n    y = 1\n    break\n",
    "for i in xs:\n    y = i\n    continue\n",
    "for a, b in xs:\n    y = a\n",
    "pass\n",
    "x += 1\n",
    "del x\n",
    "xs = [1, 2, 3]\n",
    "t = (1, 2)\n",
    "d = {1: 2}\n",
    "s = {1, 2}\n",
    "a, b = 1, 2\n",
    "raise TypeError\n",
    "try:\n    x = 1\nexcept TypeError:\n    x = 2\n",
    "try:\n    x = 1\nexcept TypeError as e:\n    x = 2\nelse:\n    x = 3\n",
    "try:\n    x = 1\nfinally:\n    x = 2\n",
    "try:\n    x = 1\nexcept (TypeError, ValueError):\n    x = 2\n",
    "assert x\n",
    "assert x, y\n",
    "@d\ndef f():\n    return 1\n",
    "@d1\n@d2\ndef f(a):\n    return a\n",
]


def _kind_names(g: dict) -> dict[int, str]:
    nd = g["ND"]
    return {num: name for name, num in nd.items()}


def firmware_shape(g: dict, nid: int) -> tuple:
    names = _kind_names(g)
    kind = g["nd_kind"][nid]
    name = names[kind]
    a = g["nd_a"][nid]
    b = g["nd_b"][nid]
    c = g["nd_c"][nid]
    obj = g["nd_obj"][nid]
    kids = g["kids"]
    if name == "Module":
        body = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("Module", body)
    if name == "Expression":
        return ("Expression", firmware_shape(g, a))
    if name == "Expr":
        return ("Expr", firmware_shape(g, a))
    if name == "Assign":
        return ("Assign", [firmware_shape(g, a)], firmware_shape(g, c))
    if name == "Return":
        value = None if a < 0 else firmware_shape(g, a)
        return ("Return", value)
    if name == "Constant":
        return ("Constant", obj)
    if name == "Name":
        return ("Name", obj, names[a])
    if name == "Attribute":
        return ("Attribute", firmware_shape(g, a), obj, names[c])
    if name == "Subscript":
        return ("Subscript", firmware_shape(g, a), firmware_shape(g, b), names[c])
    if name == "BinOp":
        return ("BinOp", firmware_shape(g, a), names[b], firmware_shape(g, c))
    if name == "UnaryOp":
        return ("UnaryOp", names[a], firmware_shape(g, b))
    if name == "BoolOp":
        values = [firmware_shape(g, kids[b + i]) for i in range(c)]
        return ("BoolOp", names[a], values)
    if name == "Compare":
        ops = [names[k] for k in obj]
        comps = [firmware_shape(g, kids[b + i]) for i in range(c)]
        return ("Compare", firmware_shape(g, a), ops, comps)
    if name == "Call":
        args = [firmware_shape(g, kids[b + i]) for i in range(c)]
        return ("Call", firmware_shape(g, a), args)
    if name == "FunctionDef":
        nargs = b & 65535
        ndec = b >> 16
        decs = [firmware_shape(g, kids[a + i]) for i in range(ndec)]
        params = [firmware_shape(g, kids[a + ndec + i]) for i in range(nargs)]
        body = [firmware_shape(g, kids[a + ndec + nargs + i]) for i in range(c)]
        return ("FunctionDef", obj, params, body, decs)
    if name == "Lambda":
        params = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("Lambda", params, firmware_shape(g, kids[a + b]))
    if name == "Assert":
        msg = None if b < 0 else firmware_shape(g, b)
        return ("Assert", firmware_shape(g, a), msg)
    if name == "JoinedStr":
        vals = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("JoinedStr", vals)
    if name == "FormattedValue":
        return ("FormattedValue", firmware_shape(g, a), b)
    if name == "Global":
        return ("Global", list(obj))
    if name == "If":
        body = [firmware_shape(g, kids[b + i]) for i in range(c)]
        orelse = [firmware_shape(g, kids[b + c + i]) for i in range(obj)]
        return ("If", firmware_shape(g, a), body, orelse)
    if name == "While":
        body = [firmware_shape(g, kids[b + i]) for i in range(c)]
        return ("While", firmware_shape(g, a), body)
    if name == "For":
        body = [firmware_shape(g, kids[c + i]) for i in range(obj)]
        return ("For", firmware_shape(g, a), firmware_shape(g, b), body)
    if name == "Pass":
        return ("Pass",)
    if name == "Break":
        return ("Break",)
    if name == "Continue":
        return ("Continue",)
    if name == "AugAssign":
        return (
            "AugAssign",
            firmware_shape(g, a),
            names[b],
            firmware_shape(g, c),
        )
    if name == "Delete":
        ts = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("Delete", ts)
    if name == "List":
        elts = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("List", elts, names[c])
    if name == "Tuple":
        elts = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("Tuple", elts, names[c])
    if name == "Set":
        elts = [firmware_shape(g, kids[a + i]) for i in range(b)]
        return ("Set", elts)
    if name == "Dict":
        keys = [firmware_shape(g, kids[a + i * 2]) for i in range(b)]
        vals = [firmware_shape(g, kids[a + i * 2 + 1]) for i in range(b)]
        return ("Dict", keys, vals)
    if name == "Slice":
        lo = None if a < 0 else firmware_shape(g, a)
        hi = None if b < 0 else firmware_shape(g, b)
        st = None if c < 0 else firmware_shape(g, c)
        return ("Slice", lo, hi, st)
    if name == "ListComp":
        return (
            "ListComp",
            firmware_shape(g, a),
            firmware_shape(g, b),
            firmware_shape(g, c),
        )
    if name == "SetComp":
        return (
            "SetComp",
            firmware_shape(g, a),
            firmware_shape(g, b),
            firmware_shape(g, c),
        )
    if name == "DictComp":
        return (
            "DictComp",
            firmware_shape(g, a),
            firmware_shape(g, b),
            firmware_shape(g, c),
            firmware_shape(g, obj),
        )
    if name == "Raise":
        exc = None if a < 0 else firmware_shape(g, a)
        return ("Raise", exc)
    if name == "ExceptHandler":
        typ = None if a < 0 else firmware_shape(g, a)
        body = [firmware_shape(g, kids[b + i]) for i in range(c)]
        return ("ExceptHandler", typ, obj or None, body)
    if name == "Try":
        norelse = obj & 65535
        nfinal = obj >> 16
        body = [firmware_shape(g, kids[a + i]) for i in range(b)]
        handlers = [firmware_shape(g, kids[a + b + i]) for i in range(c)]
        orelse = [firmware_shape(g, kids[a + b + c + i]) for i in range(norelse)]
        final = [
            firmware_shape(g, kids[a + b + c + norelse + i]) for i in range(nfinal)
        ]
        return ("Try", body, handlers, orelse, final)
    raise AssertionError(f"unhandled firmware node {name}")


def cpython_shape(node: ast.AST) -> tuple:
    if isinstance(node, ast.Module):
        return ("Module", [cpython_shape(s) for s in node.body])
    if isinstance(node, ast.Expression):
        return ("Expression", cpython_shape(node.body))
    if isinstance(node, ast.Expr):
        return ("Expr", cpython_shape(node.value))
    if isinstance(node, ast.Assign):
        return (
            "Assign",
            [cpython_shape(t) for t in node.targets],
            cpython_shape(node.value),
        )
    if isinstance(node, ast.Return):
        value = None if node.value is None else cpython_shape(node.value)
        return ("Return", value)
    if isinstance(node, ast.Constant):
        return ("Constant", node.value)
    if isinstance(node, ast.Name):
        return ("Name", node.id, type(node.ctx).__name__)
    if isinstance(node, ast.Attribute):
        return (
            "Attribute",
            cpython_shape(node.value),
            node.attr,
            type(node.ctx).__name__,
        )
    if isinstance(node, ast.Subscript):
        return (
            "Subscript",
            cpython_shape(node.value),
            cpython_shape(node.slice),
            type(node.ctx).__name__,
        )
    if isinstance(node, ast.BinOp):
        return (
            "BinOp",
            cpython_shape(node.left),
            type(node.op).__name__,
            cpython_shape(node.right),
        )
    if isinstance(node, ast.UnaryOp):
        return ("UnaryOp", type(node.op).__name__, cpython_shape(node.operand))
    if isinstance(node, ast.BoolOp):
        return (
            "BoolOp",
            type(node.op).__name__,
            [cpython_shape(v) for v in node.values],
        )
    if isinstance(node, ast.Compare):
        return (
            "Compare",
            cpython_shape(node.left),
            [type(op).__name__ for op in node.ops],
            [cpython_shape(c) for c in node.comparators],
        )
    if isinstance(node, ast.Call):
        if node.keywords:
            raise AssertionError("T1 corpus must not include keywords")
        return (
            "Call",
            cpython_shape(node.func),
            [cpython_shape(a) for a in node.args],
        )
    if isinstance(node, ast.FunctionDef):
        if node.args.defaults or node.args.kwonlyargs:
            raise AssertionError("G corpus is positional def only")
        if node.args.vararg is not None or node.args.kwarg is not None:
            raise AssertionError("G corpus is positional def only")
        params = [
            ("Name", arg.arg, "Store") for arg in node.args.args
        ]
        body = [cpython_shape(s) for s in node.body]
        decs = [cpython_shape(d) for d in node.decorator_list]
        return ("FunctionDef", node.name, params, body, decs)
    if isinstance(node, ast.Lambda):
        if node.args.defaults or node.args.kwonlyargs:
            raise AssertionError("T5 lambda is positional only")
        if node.args.vararg is not None or node.args.kwarg is not None:
            raise AssertionError("T5 lambda is positional only")
        params = [("Name", arg.arg, "Store") for arg in node.args.args]
        return ("Lambda", params, cpython_shape(node.body))
    if isinstance(node, ast.Assert):
        msg = None if node.msg is None else cpython_shape(node.msg)
        return ("Assert", cpython_shape(node.test), msg)
    if isinstance(node, ast.JoinedStr):
        return ("JoinedStr", [cpython_shape(v) for v in node.values])
    if isinstance(node, ast.FormattedValue):
        if node.format_spec is not None:
            raise AssertionError("T5 f-strings have no format spec")
        return ("FormattedValue", cpython_shape(node.value), node.conversion)
    if isinstance(node, ast.Global):
        return ("Global", list(node.names))
    if isinstance(node, ast.If):
        return (
            "If",
            cpython_shape(node.test),
            [cpython_shape(s) for s in node.body],
            [cpython_shape(s) for s in node.orelse],
        )
    if isinstance(node, ast.While):
        if node.orelse:
            raise AssertionError("T2 corpus has no while-else")
        return (
            "While",
            cpython_shape(node.test),
            [cpython_shape(s) for s in node.body],
        )
    if isinstance(node, ast.For):
        if node.orelse:
            raise AssertionError("T2 corpus has no for-else")
        return (
            "For",
            cpython_shape(node.target),
            cpython_shape(node.iter),
            [cpython_shape(s) for s in node.body],
        )
    if isinstance(node, ast.Pass):
        return ("Pass",)
    if isinstance(node, ast.Break):
        return ("Break",)
    if isinstance(node, ast.Continue):
        return ("Continue",)
    if isinstance(node, ast.AugAssign):
        return (
            "AugAssign",
            cpython_shape(node.target),
            type(node.op).__name__,
            cpython_shape(node.value),
        )
    if isinstance(node, ast.Delete):
        return ("Delete", [cpython_shape(t) for t in node.targets])
    if isinstance(node, ast.List):
        return (
            "List",
            [cpython_shape(e) for e in node.elts],
            type(node.ctx).__name__,
        )
    if isinstance(node, ast.Tuple):
        return (
            "Tuple",
            [cpython_shape(e) for e in node.elts],
            type(node.ctx).__name__,
        )
    if isinstance(node, ast.Set):
        return ("Set", [cpython_shape(e) for e in node.elts])
    if isinstance(node, ast.Dict):
        return (
            "Dict",
            [cpython_shape(k) for k in node.keys],
            [cpython_shape(v) for v in node.values],
        )
    if isinstance(node, ast.Slice):
        lo = None if node.lower is None else cpython_shape(node.lower)
        hi = None if node.upper is None else cpython_shape(node.upper)
        st = None if node.step is None else cpython_shape(node.step)
        return ("Slice", lo, hi, st)
    if isinstance(node, ast.ListComp):
        if len(node.generators) != 1 or node.generators[0].ifs:
            raise AssertionError("T4 corpus is one generator, no ifs")
        gen = node.generators[0]
        return (
            "ListComp",
            cpython_shape(node.elt),
            cpython_shape(gen.target),
            cpython_shape(gen.iter),
        )
    if isinstance(node, ast.SetComp):
        if len(node.generators) != 1 or node.generators[0].ifs:
            raise AssertionError("T4 corpus is one generator, no ifs")
        gen = node.generators[0]
        return (
            "SetComp",
            cpython_shape(node.elt),
            cpython_shape(gen.target),
            cpython_shape(gen.iter),
        )
    if isinstance(node, ast.DictComp):
        if len(node.generators) != 1 or node.generators[0].ifs:
            raise AssertionError("T4 corpus is one generator, no ifs")
        gen = node.generators[0]
        return (
            "DictComp",
            cpython_shape(node.key),
            cpython_shape(node.value),
            cpython_shape(gen.target),
            cpython_shape(gen.iter),
        )
    if isinstance(node, ast.Raise):
        if node.cause is not None:
            raise AssertionError("T4 corpus has no raise-from")
        exc = None if node.exc is None else cpython_shape(node.exc)
        return ("Raise", exc)
    if isinstance(node, ast.ExceptHandler):
        typ = None if node.type is None else cpython_shape(node.type)
        body = [cpython_shape(s) for s in node.body]
        return ("ExceptHandler", typ, node.name, body)
    if isinstance(node, ast.Try):
        return (
            "Try",
            [cpython_shape(s) for s in node.body],
            [cpython_shape(h) for h in node.handlers],
            [cpython_shape(s) for s in node.orelse],
            [cpython_shape(s) for s in node.finalbody],
        )
    raise AssertionError(f"unhandled CPython node {type(node).__name__}")


def firmware_parse(src: str, mode: str) -> tuple:
    g = load_firmware_package_namespace()
    g["_in_src"] = src
    g["_in_mode"] = mode
    _host_exec_globals(g["_pyc_parse_main"], g)
    root = g["nd_n"] - 1
    return firmware_shape(g, root), g["nd_n"], g["_pyc_ast_checksum"]()


class TestCompilerParserCorpus(unittest.TestCase):
    def test_eval_corpus_matches_ast_parse(self) -> None:
        for src in PARSER_EVAL_CORPUS:
            with self.subTest(src=src):
                got, _, _ = firmware_parse(src, "eval")
                want = cpython_shape(ast.parse(src, mode="eval"))
                self.assertEqual(got, want)

    def test_exec_corpus_matches_ast_parse(self) -> None:
        for src in PARSER_EXEC_CORPUS:
            with self.subTest(src=src):
                got, _, _ = firmware_parse(src, "exec")
                want = cpython_shape(ast.parse(src, mode="exec"))
                self.assertEqual(got, want)

    def test_tiny_expr_node_count(self) -> None:
        _, n, _ = firmware_parse("1 + 2", "eval")
        self.assertEqual(n, 4)

    def test_deep_nesting_node_count(self) -> None:
        src = "(" * 40 + "1" + ")" * 40
        _, n, _ = firmware_parse(src, "eval")
        self.assertEqual(n, 2)

    def test_list_display_shape(self) -> None:
        src = "[1, 2]"
        got, _, _ = firmware_parse(src, "eval")
        want = cpython_shape(ast.parse(src, mode="eval"))
        self.assertEqual(got, want)

    def test_function_def_shape(self) -> None:
        src = "def f(a, b):\n    x = a + b\n    return x\n"
        got, _, _ = firmware_parse(src, "exec")
        want = cpython_shape(ast.parse(src, mode="exec"))
        self.assertEqual(got, want)

    def test_unsupported_class(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "class C:\n    x = 1\n"
        g["_in_mode"] = "exec"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_parse_main"], g)

    def test_unsupported_async_def(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "async def f():\n    return 1\n"
        g["_in_mode"] = "exec"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_parse_main"], g)

    def test_unsupported_with(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "with x:\n    y = 1\n"
        g["_in_mode"] = "exec"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_parse_main"], g)

    def test_fstring_format_spec_rejected(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = 'f"{x:02d}"'
        g["_in_mode"] = "eval"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_parse_main"], g)

    def test_unsupported_default_arg(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "def f(a=1):\n    return a\n"
        g["_in_mode"] = "exec"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_parse_main"], g)

    def test_img_parser_tiny_expr_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_parser_tiny_expr.py", "managed_entry"),
            firmware_parse("1 + 2", "eval")[2],
        )

    def test_img_compile_deep_nesting_host_golden(self) -> None:
        src = "(" * 40 + "1" + ")" * 40
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_deep_nesting.py", "managed_entry"),
            firmware_parse(src, "eval")[2],
        )


if __name__ == "__main__":
    unittest.main()
