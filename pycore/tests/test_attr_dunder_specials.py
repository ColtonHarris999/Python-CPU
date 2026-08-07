"""Unit tests for LOAD_ATTR dunder specials tooling + image builds."""

from __future__ import annotations

import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("attr dunder tests require Python 3.14")

from pycore.tools import image_from_source
from pycore.tools.run_image_test import host_entry_result

# Packed SHORT_STR values must match pycore_defs.svh PY_ATTR_NAME_*.
_ATTR_NAME_HEX = {
    "__dict__": "85f5f646963745f5f000000000000000",
    "__class__": "95f5f636c6173735f5f0000000000000",
    "__base__": "85f5f626173655f5f000000000000000",
}


def _pack_short_str(s: str) -> int:
    size = len(s)
    payload = 0
    for i, ch in enumerate(s.encode("ascii")):
        bit_hi = 119 - i * 8
        payload |= ch << (bit_hi - 7)
    return (size << 124) | (payload << 4)


class AttrDunderNamePackTest(unittest.TestCase):
    def test_short_str_constants_match_rtl(self) -> None:
        for name, hex_val in _ATTR_NAME_HEX.items():
            with self.subTest(name=name):
                self.assertEqual(f"{_pack_short_str(name):032x}", hex_val)


class SeedTypeBaseTest(unittest.TestCase):
    def test_parse_seed_type_base(self) -> None:
        text = (
            "# pycore-inject: SEED_TYPE Base\n"
            "# pycore-inject: SEED_TYPE Child base=Base\n"
            "# pycore-inject: SEED_INSTANCE o type=Child slots=4\n"
        )
        seeds = image_from_source.parse_seed_pragmas(text)
        self.assertEqual(len(seeds.types), 2)
        self.assertIsNone(seeds.types[0].base_name)
        self.assertEqual(seeds.types[1].base_name, "Base")
        self.assertEqual(seeds.instances[0].type_name, "Child")

    def test_seed_base_unknown_raises(self) -> None:
        text = (
            "# pycore-inject: SEED_TYPE Child base=Missing\n"
            "def managed_entry():\n"
            "    return 0\n"
            "\n"
            "managed_entry()\n"
        )
        with self.assertRaises(ValueError):
            image_from_source.build_image_from_source_text(text, "<bad-base>")


DUNDER_PROGRAM_GOLDENS = {
    "img_attr_dunder_dict.py": 12,
    "img_attr_dunder_class.py": 1,
    "img_attr_dunder_base.py": 7,
    "img_firmware_attr_helpers.py": 31,
    "img_firmware_isinstance.py": 127,
}


class AttrDunderImageBuildTest(unittest.TestCase):
    def test_dunder_programs_build_and_host_golden(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for fname, expect in DUNDER_PROGRAM_GOLDENS.items():
            with self.subTest(program=fname):
                path = root / fname
                text = path.read_text(encoding="utf-8")
                image = image_from_source.build_image_from_source_text(text, fname)
                self.assertGreater(len(image.program_slots), 0)
                self.assertEqual(host_entry_result(path, "managed_entry"), expect)

    def test_trap_programs_build(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for name in (
            "img_attr_dunder_store_trap.py",
            "img_attr_dunder_del_trap.py",
        ):
            with self.subTest(program=name):
                text = (root / name).read_text(encoding="utf-8")
                image = image_from_source.build_image_from_source_text(text, name)
                self.assertGreater(len(image.program_slots), 0)


class Wave4AttrRomSeedTest(unittest.TestCase):
    WAVE4_ATTR_NAMES = {
        "hasattr",
        "getattr",
        "setattr",
        "delattr",
        "isinstance",
        "issubclass",
    }

    def test_wave4_attr_names_in_rom_registry(self) -> None:
        keys = {k for k, _, _ in image_from_source.ROM_FIRMWARE_BUILTINS}
        self.assertTrue(self.WAVE4_ATTR_NAMES.issubset(keys), keys)
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 27)

    def test_attr_firmware_validate(self) -> None:
        for name in sorted(self.WAVE4_ATTR_NAMES):
            path = image_from_source.FIRMWARE_BUILTINS_DIR / f"{name}.py"
            source = path.read_text(encoding="utf-8")
            ns: dict[str, object] = {}
            exec(compile(source, str(path), "exec"), ns)
            image_from_source.validate_code_tree(ns[name].__code__)


if __name__ == "__main__":
    unittest.main()
