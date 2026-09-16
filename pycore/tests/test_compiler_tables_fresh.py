"""CI gate: regenerating compiler tables.py is a no-op (compiler_design.md W-6)."""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler tables tests require Python 3.14")

from gen_compiler_tables import DEFAULT_OUTPUT, generate_tables_text


class TestCompilerTablesFresh(unittest.TestCase):
    def test_checked_in_matches_generator(self) -> None:
        generated = generate_tables_text()
        checked_in = DEFAULT_OUTPUT.read_text(encoding="utf-8")
        self.assertEqual(checked_in, generated)

    def test_emit_ops_match_opmap_keys(self) -> None:
        ns: dict[str, object] = {}
        exec(
            compile(
                DEFAULT_OUTPUT.read_text(encoding="utf-8"),
                str(DEFAULT_OUTPUT),
                "exec",
            ),
            ns,
        )
        opmap = ns["OPMAP"]
        emit_ops = ns["EMIT_OPS"]
        execute_ops = ns["EXECUTE_OPS"]
        self.assertIsInstance(opmap, dict)
        self.assertIsInstance(emit_ops, list)
        self.assertEqual(list(opmap.keys()), emit_ops)
        self.assertEqual(emit_ops, sorted(emit_ops))
        self.assertTrue(set(execute_ops).issubset(set(emit_ops)))
        self.assertIn("RESUME", opmap)
        self.assertIn("CALL", opmap)
        self.assertIn("LOAD_GLOBAL", opmap)
        self.assertIn("CACHE", opmap)
        self.assertIn("EXTENDED_ARG", opmap)
        keywords = ns["KEYWORDS"]
        self.assertIn("def", keywords)
        self.assertEqual(keywords["def"], 1)
        self.assertEqual(ns["TOK_NAME"], 1)
        self.assertEqual(ns["TOK_OP"], 55)
        self.assertEqual(ns["TOK_NEWLINE"], 4)
        self.assertIn("...", ns["OP3"])
        self.assertIn("==", ns["OP2"])
        self.assertEqual(ns["ND"]["BinOp"], ns["ND_BINOP"])
        self.assertEqual(ns["BINOPS"]["+"], ns["ND_ADD"])
        self.assertEqual(ns["CMPOPS"]["<="], ns["ND_LTE"])
        self.assertEqual(ns["PREC"]["**"], 12)
        self.assertEqual(ns["RIGHTASSOC"]["**"], 1)
        self.assertIn("Not", ns["ND"])


if __name__ == "__main__":
    unittest.main()
