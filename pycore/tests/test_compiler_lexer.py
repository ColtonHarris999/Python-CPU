"""Host token-stream differential vs CPython ``tokenize`` (compiler_design.md E)."""

from __future__ import annotations

import io
import sys
import tokenize
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler lexer tests require Python 3.14")

from image_from_source import load_firmware_package_namespace, _host_exec_globals


_SKIP_KINDS = {
    tokenize.COMMENT,
    tokenize.NL,
    tokenize.ENCODING,
}


LEXER_CORPUS = [
    "",
    "\n",
    "x = 1 + 2\n",
    "x=1",
    "def f(a, b):\n    return a + b\n",
    "def f():\n    pass\n",
    "if x:\n    y\nelse:\n    z\n",
    "if 1:\n    if 1:\n        x\n    y\n",
    "s = 'hi'\n",
    's = "hi"\n',
    "s = '''ab\ncd'''\n",
    "s = r'hi'\n",
    "s = b'hi'\n",
    "# comment\nx=1\n",
    "x # c\n",
    "(\n  1 +\n  2\n)\n",
    "a\\\n+ b\n",
    "0x1f 1.5 1e3 .5\n",
    "1. 00 0e0\n",
    "a.b\n",
    "a == b != c <= d >= e\n",
    "a += 1\n",
    "x := 1\n",
    "...\n",
    "a[0]\n",
    "{1:2}\n",
    "**a\n",
    "a, *b\n",
    "x@y\n",
    "x -> y\n",
    "def f(\n    a,\n    b):\n    return a\n",
    "if 1:\n    pass\n        \n    x\n",
    "async def f():\n    await x\n",
    "1_000\n",
    "0x_ff\n",
    "2j\n",
    '"hi\\n"\n',
    "def f():\n    x=1",
    'f"hello"\n',
    'f"a{x}b"\n',
    'f"{x}"\n',
    'f"{x!s}"\n',
    "f'hi'\n",
    'rf"a{x}"\n',
    'f"""a{x}b"""\n',
    'f""\n',
    'f"a{x}{y}b"\n',
]


def _line_starts(src: str) -> list[int]:
    starts = [0]
    i = 0
    n = len(src)
    while i < n:
        if src[i] == "\n":
            starts.append(i + 1)
        i += 1
    if not starts or starts[len(starts) - 1] != n:
        starts.append(n)
    return starts


def _offset(starts: list[int], loc: tuple[int, int], src_len: int) -> int:
    line, col = loc
    idx = line - 1
    if idx >= len(starts):
        return src_len
    if idx < 0:
        return 0
    return starts[idx] + col


def cpython_tokens(src: str) -> list[tuple[int, int, int, int, int, str | None]]:
    """Return (kind, line, col, start, end, text_or_none) skipping COMMENT/NL/ENCODING."""
    starts = _line_starts(src)
    n = len(src)
    out: list[tuple[int, int, int, int, int, str | None]] = []
    readline = io.StringIO(src).readline
    for tok in tokenize.generate_tokens(readline):
        if tok.type in _SKIP_KINDS:
            continue
        start = _offset(starts, tok.start, n)
        end = _offset(starts, tok.end, n)
        text: str | None
        if tok.type in (
            tokenize.NAME,
            tokenize.NUMBER,
            tokenize.STRING,
            tokenize.OP,
            tokenize.FSTRING_START,
            tokenize.FSTRING_MIDDLE,
            tokenize.FSTRING_END,
        ):
            text = tok.string
        else:
            text = None
        out.append((tok.type, tok.start[0], tok.start[1], start, end, text))
    return out


def firmware_tokens(src: str) -> list[tuple[int, int, int, int, int, object]]:
    g = load_firmware_package_namespace()
    g["_in_src"] = src
    count = _host_exec_globals(g["_pyc_lex_main"], g)
    tk_a = g["tk_a"]
    tk_b = g["tk_b"]
    tk_s = g["tk_s"]
    out: list[tuple[int, int, int, int, int, object]] = []
    i = 0
    while i < count:
        packed_a = tk_a[i]
        packed_b = tk_b[i]
        kind = packed_a & 255
        col = (packed_a >> 8) & 65535
        line = packed_a >> 24
        start = packed_b & ((1 << 32) - 1)
        end = packed_b >> 32
        text = tk_s[i]
        if kind not in (
            tokenize.NAME,
            tokenize.NUMBER,
            tokenize.STRING,
            tokenize.OP,
            tokenize.FSTRING_START,
            tokenize.FSTRING_MIDDLE,
            tokenize.FSTRING_END,
        ):
            text = None
        elif text == 0:
            text = None
        out.append((kind, line, col, start, end, text))
        i += 1
    return out


class TestCompilerLexerCorpus(unittest.TestCase):
    def test_corpus_matches_generate_tokens(self) -> None:
        for src in LEXER_CORPUS:
            with self.subTest(src=src):
                self.assertEqual(firmware_tokens(src), cpython_tokens(src))

    def test_img_source_token_count(self) -> None:
        src = "def f(a, b):\n    return a + b\n"
        self.assertEqual(len(firmware_tokens(src)), 17)

    def test_unindent_raises(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "def f():\n    x\n  y\n"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_lex_main"], g)

    def test_unterminated_string_raises(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "'unterminated\n"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_lex_main"], g)

    def test_tstring_raises(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = 't"hi"\n'
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_lex_main"], g)

    def test_nested_fstring_raises(self) -> None:
        g = load_firmware_package_namespace()
        g["_in_src"] = "f\"{f'{x}'}\"\n"
        with self.assertRaises(SyntaxError):
            _host_exec_globals(g["_pyc_lex_main"], g)


if __name__ == "__main__":
    unittest.main()
