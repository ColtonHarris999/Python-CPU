"""Host unit tests for the SEED_CODE pragma (Plan 1 P3)."""

import unittest

from image_from_source import (
    HOST_STANDIN_BUILTINS,
    ROM_FIRMWARE_BUILTINS,
    parse_seed_pragmas,
)


class TestSeedCodePragma(unittest.TestCase):
    def parse(self, line: str):
        return parse_seed_pragmas(line).codes

    def test_minimal(self):
        (spec,) = self.parse('# pycore-inject: SEED_CODE s source="x = 1"')
        self.assertEqual(spec.name, "s")
        self.assertEqual(spec.mode, "exec")
        self.assertEqual(spec.source, "x = 1")

    def test_mode_eval(self):
        (spec,) = self.parse('# pycore-inject: SEED_CODE e mode=eval source="a + 1"')
        self.assertEqual(spec.mode, "eval")
        self.assertEqual(spec.source, "a + 1")

    def test_newline_and_tab_escapes(self):
        (spec,) = self.parse(
            '# pycore-inject: SEED_CODE s source="a = 1\\nb = 2"'
        )
        self.assertEqual(spec.source, "a = 1\nb = 2")

    def test_single_quotes(self):
        (spec,) = self.parse("# pycore-inject: SEED_CODE s source='x = 1'")
        self.assertEqual(spec.source, "x = 1")

    def test_source_may_contain_spaces_and_equals(self):
        (spec,) = self.parse(
            '# pycore-inject: SEED_CODE s source="x = y == z"'
        )
        self.assertEqual(spec.source, "x = y == z")

    def test_empty_source_allowed(self):
        (spec,) = self.parse('# pycore-inject: SEED_CODE s source=""')
        self.assertEqual(spec.source, "")

    def test_multiple_pragmas_keep_order(self):
        text = (
            '# pycore-inject: SEED_CODE a source="p = 1"\n'
            '# pycore-inject: SEED_CODE b mode=eval source="p"\n'
        )
        specs = parse_seed_pragmas(text).codes
        self.assertEqual([s.name for s in specs], ["a", "b"])
        self.assertEqual([s.mode for s in specs], ["exec", "eval"])

    def test_indented_pragma_is_parsed(self):
        (spec,) = self.parse('    # pycore-inject: SEED_CODE s source="x = 1"')
        self.assertEqual(spec.name, "s")

    def test_names_include_seeded_codes(self):
        specs = parse_seed_pragmas(
            '# pycore-inject: SEED_CODE snip source="x = 1"'
        )
        self.assertIn("snip", specs.global_names)

    # --- rejections -----------------------------------------------------

    def test_missing_source_rejected(self):
        with self.assertRaises(ValueError):
            self.parse("# pycore-inject: SEED_CODE s mode=exec")

    def test_unquoted_source_rejected(self):
        with self.assertRaises(ValueError):
            self.parse("# pycore-inject: SEED_CODE s source=x=1")

    def test_mismatched_quotes_rejected(self):
        with self.assertRaises(ValueError):
            self.parse("# pycore-inject: SEED_CODE s source=\"x = 1'")

    def test_bad_mode_rejected(self):
        with self.assertRaises(ValueError):
            self.parse(
                '# pycore-inject: SEED_CODE s mode=single source="x = 1"'
            )

    def test_unknown_option_rejected(self):
        with self.assertRaises(ValueError):
            self.parse('# pycore-inject: SEED_CODE s slots=4 source="x = 1"')

    def test_missing_name_rejected(self):
        with self.assertRaises(ValueError):
            self.parse('# pycore-inject: SEED_CODE source="x = 1"')


class TestExecEvalRegistration(unittest.TestCase):
    def test_exec_and_eval_are_rom_seeded(self):
        keys = {k for k, _stem, _fn in ROM_FIRMWARE_BUILTINS}
        self.assertIn("exec", keys)
        self.assertIn("eval", keys)

    def test_host_standins_are_declared_for_them(self):
        # Their ROM bodies call the code object, which CPython cannot do, so
        # run_image_test.py must override them.
        self.assertEqual(HOST_STANDIN_BUILTINS, {"exec", "eval"})


if __name__ == "__main__":
    unittest.main()
