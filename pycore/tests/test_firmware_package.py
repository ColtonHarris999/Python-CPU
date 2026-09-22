"""Host tests for firmware package seeding (compiler_design.md W-1 / W-2)."""

from __future__ import annotations

import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("firmware package tests require Python 3.14")

from encoding import CODE_RAM_SLOT_BASE, TAG_CODE_OBJECT, TAG_MUT_COLLEC
from image_from_source import (
    PACKAGE_ENTRY_NAME,
    PACKAGE_RUNTIME_SEEDS,
    PACKAGE_TABLE_SEED_NAMES,
    _ImageSerializer,
    _package_dict_slots,
    build_image_from_source_text,
    compile_package_entry,
    load_firmware_package_functions,
    load_firmware_package_namespace,
    load_firmware_package_tables,
    load_rom_firmware_callables,
    seed_firmware_package,
)
from run_image_test import host_entry_result


PROGRAMS = pathlib.Path(__file__).resolve().parents[1] / "programs"


class TestFirmwarePackageSeed(unittest.TestCase):
    def test_package_functions_are_named_helpers(self) -> None:
        fns = load_firmware_package_functions()
        self.assertIn("_pyc_inc", fns)
        self.assertIn("_pyc_add", fns)
        self.assertEqual(fns["_pyc_inc"](40), 41)
        self.assertEqual(fns["_pyc_add"](41, 1), 42)

    def test_entry_trampoline_calls_helpers(self) -> None:
        fns = load_firmware_package_functions()
        entry = compile_package_entry()
        self.assertEqual(entry.__name__, PACKAGE_ENTRY_NAME)
        self.assertEqual(entry.__code__.co_argcount, 0)
        g = dict(fns)
        self.assertEqual(eval(entry.__code__, g), 42)

    def test_seed_places_bodies_in_code_ram(self) -> None:
        serializer = _ImageSerializer()
        result = seed_firmware_package(serializer)
        self.assertIsNotNone(result)
        pyc_g, pyc_entry = result
        self.assertEqual(pyc_g[0], TAG_MUT_COLLEC)
        self.assertEqual(pyc_entry[0], TAG_CODE_OBJECT)
        self.assertGreater(len(serializer.code_ram_slots), 0)
        self.assertEqual(len(serializer.program_slots), 0)
        self.assertEqual(
            serializer.code_ram_init_slot(),
            CODE_RAM_SLOT_BASE + len(serializer.code_ram_slots),
        )
        ram_slots = [
            slot
            for slot in serializer.entry_slots.values()
            if slot >= CODE_RAM_SLOT_BASE
        ]
        self.assertEqual(len(ram_slots), len(serializer.entry_slots))
        self.assertTrue(all(slot >= CODE_RAM_SLOT_BASE for slot in ram_slots))

    def test_whole_image_code_ram_skips_package(self) -> None:
        serializer = _ImageSerializer(slot_base=CODE_RAM_SLOT_BASE)
        self.assertIsNone(seed_firmware_package(serializer))
        self.assertEqual(serializer.code_ram_slots, [])

    def test_image_meta_reports_code_ram_init_slot(self) -> None:
        image = build_image_from_source_text(
            "def managed_entry():\n    return 1\n\nmanaged_entry()\n",
            "<pkg-seed>",
        )
        self.assertGreater(len(image.code_ram_slots), 0)
        self.assertEqual(
            image.code_ram_init_slot,
            CODE_RAM_SLOT_BASE + len(image.code_ram_slots),
        )
        ram_slots = [
            slot for slot in image.entry_slots.values() if slot >= CODE_RAM_SLOT_BASE
        ]
        self.assertGreaterEqual(len(ram_slots), 3)  # two helpers + trampoline

    def test_code_ram_relocated_image_has_empty_package_bank(self) -> None:
        image = build_image_from_source_text(
            "def managed_entry():\n    return 1\n\nmanaged_entry()\n",
            "<pkg-seed-ram>",
            slot_base=CODE_RAM_SLOT_BASE,
        )
        self.assertEqual(image.code_ram_slots, [])
        self.assertEqual(
            image.code_ram_init_slot,
            CODE_RAM_SLOT_BASE + len(image.program_slots),
        )

    def test_host_standins_expose_package_names(self) -> None:
        ns = load_rom_firmware_callables()
        self.assertIn("_PYC_G", ns)
        self.assertIn("_PYC_ENTRY", ns)
        self.assertIn("_bi_exec_globals", ns)
        self.assertIn("compile", ns)
        self.assertEqual(ns["_bi_exec_globals"](ns["_PYC_ENTRY"], ns["_PYC_G"]), 42)
        g = ns["_PYC_G"]
        self.assertIn("TOK_NAME", g)
        self.assertEqual(g["TOK_NAME"], 1)
        self.assertIn("_pyc_lex_main", g)
        self.assertIn("OP3", g)
        self.assertIn("_in_src", g)
        self.assertEqual(g["_in_src"], "")

    def test_package_namespace_includes_tables_and_lexer(self) -> None:
        g = load_firmware_package_namespace()
        self.assertEqual(g["TOK_OP"], 55)
        self.assertIn("_pyc_lex", g)
        self.assertIn("_pyc_lex_main", g)
        self.assertIn("_pyc_parse_main", g)
        self.assertIn("_pyc_symtab_main", g)
        self.assertIn("_pyc_codegen_main", g)
        self.assertIn("ND", g)
        self.assertEqual(g["ND"]["BinOp"], 14)

    def test_device_seed_key_count_fits_static_dict(self) -> None:
        tables = load_firmware_package_tables()
        missing = PACKAGE_TABLE_SEED_NAMES - set(tables)
        self.assertEqual(missing, set())
        functions = load_firmware_package_functions()
        n = (
            len(PACKAGE_TABLE_SEED_NAMES)
            + len(functions)
            + len(PACKAGE_RUNTIME_SEEDS)
        )
        slots = _package_dict_slots(n)
        # Open addressing, so headroom is the point: the table must stay at
        # or under 50% load, not merely have one free slot. A near-full
        # _PYC_G is what forced the "127 of 128 keys" freeze that blocked
        # adding compiler helpers (compiler_design.md D9).
        self.assertLessEqual(n * 2, slots)

    def test_img_pyc_package_call_host_golden(self) -> None:
        self.assertEqual(
            host_entry_result(PROGRAMS / "img_pyc_package_call.py", "managed_entry"),
            42,
        )


if __name__ == "__main__":
    unittest.main()
