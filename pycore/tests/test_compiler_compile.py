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

    def test_img_code_kind_tags_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_code_kind_tags.py", "managed_entry"),
            178,
        )


if __name__ == "__main__":
    unittest.main()
