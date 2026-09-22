"""Host tests for the ROM compile() shim (compiler_design.md I)."""

from __future__ import annotations

import pathlib
import sys
import types
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("compiler compile-shim tests require Python 3.14")

from image_from_source import (
    HOST_STANDIN_BUILTINS,
    ROM_FIRMWARE_BUILTINS,
    _HostEmittedCode,
    load_rom_firmware_callables,
    seed_firmware_function,
    _ImageSerializer,
)
from run_image_test import host_entry_result

PROGRAMS = pathlib.Path(__file__).resolve().parents[1] / "programs"
FIRMWARE = (
    pathlib.Path(__file__).resolve().parents[2]
    / "pycore_firmware"
    / "builtins"
    / "compile.py"
)


class TestCompilerCompileShim(unittest.TestCase):
    def test_compile_is_a_rom_firmware_builtin(self) -> None:
        keys = {k for k, _, _ in ROM_FIRMWARE_BUILTINS}
        self.assertIn("compile", keys)
        self.assertNotIn("compile", HOST_STANDIN_BUILTINS)

    def test_defaults_are_flags_dont_inherit_optimize(self) -> None:
        serializer = _ImageSerializer()
        seed_firmware_function(serializer, FIRMWARE, "compile")
        self.assertTrue(
            any(v == (0, False, -1) for v in serializer.defaults_map.values()),
            serializer.defaults_map,
        )

    def test_host_compile_eval_one_plus_two(self) -> None:
        ns = load_rom_firmware_callables()
        compile_fn = ns["compile"]
        self.assertIn("_PYC_G", compile_fn.__globals__)
        self.assertIn("_bi_exec_globals", compile_fn.__globals__)
        co = compile_fn("1 + 2", "<s>", "eval")
        self.assertIsInstance(co, _HostEmittedCode)
        self.assertNotIsInstance(co, types.CodeType)
        self.assertEqual(co(), 3)

    def test_entry_trampoline_is_still_the_toy(self) -> None:
        ns = load_rom_firmware_callables()
        self.assertEqual(ns["_bi_exec_globals"](ns["_PYC_ENTRY"], ns["_PYC_G"]), 42)

    def test_mode_and_flags_raise_value_error(self) -> None:
        compile_fn = load_rom_firmware_callables()["compile"]
        with self.assertRaises(ValueError):
            compile_fn("1", "<s>", "single")
        with self.assertRaises(ValueError):
            compile_fn("1", "<s>", "eval", 1)
        with self.assertRaises(ValueError):
            compile_fn("1", "<s>", "unknown")
        with self.assertRaises(ValueError):
            compile_fn("1", "<s>", "eval", 0, False, 1)

    def test_import_is_syntax_error(self) -> None:
        compile_fn = load_rom_firmware_callables()["compile"]
        with self.assertRaises(SyntaxError) as cm:
            compile_fn("import os", "<s>", "exec")
        self.assertIn("import", str(cm.exception))

    def test_img_compile_eval_expr_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_eval_expr.py", "managed_entry"),
            3,
        )

    def test_img_compile_mode_trap_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_mode_trap.py", "managed_entry"),
            3,
        )

    def test_img_compile_reject_import_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_reject_import.py", "managed_entry"),
            1,
        )

    def test_img_compile_reject_closure_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_reject_closure.py", "managed_entry"
            ),
            1,
        )

    def test_img_compile_closure_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_closure.py", "managed_entry"),
            7,
        )

    def test_img_compile_exec_roundtrip_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_exec_roundtrip.py", "managed_entry"
            ),
            7,
        )

    def test_img_compile_reject_locals_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_reject_locals.py", "managed_entry"
            ),
            1,
        )

    def test_img_eval_str_direct_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_eval_str_direct.py", "managed_entry"),
            3,
        )

    def test_img_eval_str_long_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_eval_str_long.py", "managed_entry"),
            15,
        )

    def test_img_exec_str_direct_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_exec_str_direct.py", "managed_entry"),
            3,
        )

    def test_img_bios_exec_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_bios_exec.py", "managed_entry"),
            3,
        )

    def test_img_code_kind_tags_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_code_kind_tags.py", "managed_entry"),
            178,
        )

    def test_img_compile_repeat_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_repeat.py", "managed_entry"),
            1,
        )

    def test_img_compile_release_realloc_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_release_realloc.py", "managed_entry"
            ),
            37,
        )

    def test_host_compile_twice_without_marks(self) -> None:
        compile_fn = load_rom_firmware_callables()["compile"]
        self.assertEqual(compile_fn("1 + 2", "<s>", "eval")(), 3)
        self.assertEqual(compile_fn("3 + 4", "<s>", "eval")(), 7)

    def test_img_compile_try_except_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_try_except.py", "managed_entry"),
            7,
        )

    def test_img_compile_try_else_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_try_else.py", "managed_entry"),
            3,
        )

    def test_img_compile_try_finally_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_try_finally.py", "managed_entry"),
            12,
        )

    def test_img_compile_raise_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_raise.py", "managed_entry"),
            7,
        )

    def test_img_compile_str_slice_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_str_slice.py", "managed_entry"),
            1,
        )

    def test_img_compile_list_comp_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_list_comp.py", "managed_entry"),
            15,
        )

    def test_img_compile_lambda_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_lambda.py", "managed_entry"),
            7,
        )

    def test_img_compile_assert_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_assert.py", "managed_entry"),
            1,
        )

    def test_img_compile_decorator_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_decorator.py", "managed_entry"),
            7,
        )

    def test_img_compile_fstring_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_fstring.py", "managed_entry"),
            1,
        )

    def test_img_compile_const_pool_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_const_pool.py", "managed_entry"),
            7,
        )

    def test_reentrant_compile_raises_instead_of_clobbering(self) -> None:
        """D9: the argument slots are module state on ``_PYC_G``.

        A ``compile()`` reached from inside a compiled-and-executed program
        would overwrite the outer call's ``_in_src`` mid-parse. The guard
        makes that a clean ``ValueError``.
        """
        ns = load_rom_firmware_callables()
        compile_fn = ns["compile"]
        package = compile_fn.__globals__["_PYC_G"]
        self.assertEqual(package["_busy"], 0)
        package["_busy"] = 1
        try:
            with self.assertRaises(ValueError):
                compile_fn("1 + 2", "<s>", "eval")
        finally:
            package["_busy"] = 0

    def test_busy_is_cleared_after_a_failed_compile(self) -> None:
        """A SyntaxError must not poison the next call."""
        ns = load_rom_firmware_callables()
        compile_fn = ns["compile"]
        package = compile_fn.__globals__["_PYC_G"]
        with self.assertRaises(SyntaxError):
            compile_fn("import os", "<s>", "exec")
        self.assertEqual(package["_busy"], 0)
        self.assertEqual(compile_fn("3 + 4", "<s>", "eval")(), 7)

    def test_busy_is_cleared_after_a_mode_error(self) -> None:
        ns = load_rom_firmware_callables()
        compile_fn = ns["compile"]
        package = compile_fn.__globals__["_PYC_G"]
        with self.assertRaises(ValueError):
            compile_fn("1", "<s>", "single")
        self.assertEqual(package["_busy"], 0)

    def test_img_str_eq_runtime_long_host_golden(self) -> None:
        """T0: the LONG_STR equality/ordering the design was built on."""
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_str_eq_runtime_long.py", "managed_entry"
            ),
            63,
        )

    def test_img_startup_multiprogram_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_startup_multiprogram.py", "managed_entry"
            ),
            7,
        )

    def test_img_compile_kwargs_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_kwargs.py", "managed_entry"),
            7,
        )

    def test_img_compile_grammar_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_compile_grammar.py", "managed_entry"),
            7,
        )

    def test_img_compile_reentrant_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_reentrant.py", "managed_entry"
            ),
            7,
        )

    def test_img_compile_ns_inherit_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(
                PROGRAMS / "img_compile_ns_inherit.py", "managed_entry"
            ),
            7,
        )

    def test_class_and_with_remain_syntax_error(self) -> None:
        compile_fn = load_rom_firmware_callables()["compile"]
        with self.assertRaises(SyntaxError):
            compile_fn("class C:\n    x = 1\n", "<s>", "exec")
        with self.assertRaises(SyntaxError):
            compile_fn("with x:\n    y = 1\n", "<s>", "exec")


if __name__ == "__main__":
    unittest.main()
