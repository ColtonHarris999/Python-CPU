"""Unit tests for ROM firmware builtin seeding into the boot builtins dict."""

from __future__ import annotations

import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("ROM firmware seed tests require Python 3.14")

from encoding import TAG_CODE_OBJECT
from pycore.tools import image_from_source


class RomFirmwareSeedTest(unittest.TestCase):
    def test_registry_sources_validate(self) -> None:
        for dict_key, stem, func_name in image_from_source.ROM_FIRMWARE_BUILTINS:
            path = image_from_source.FIRMWARE_BUILTINS_DIR / f"{stem}.py"
            self.assertTrue(path.is_file(), f"missing firmware source {path}")
            source = path.read_text(encoding="utf-8")
            ns: dict[str, object] = {}
            exec(compile(source, str(path), "exec"), ns)
            func = ns[func_name]
            image_from_source.validate_code_tree(func.__code__)
            self.assertEqual(dict_key, func_name)

    def test_seed_firmware_function_returns_code_object(self) -> None:
        serializer = image_from_source._ImageSerializer()
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "sum.py"
        handle = image_from_source.seed_firmware_function(serializer, path, "sum")
        self.assertEqual(handle[0], TAG_CODE_OBJECT)
        self.assertGreater(len(serializer.program_slots), 0)
        self.assertTrue(any(v == (0,) for v in serializer.defaults_map.values()))

    def test_seed_rom_firmware_builtins_all_code_objects(self) -> None:
        pairs = image_from_source.seed_rom_firmware_builtins(
            image_from_source._ImageSerializer()
        )
        self.assertEqual(len(pairs), len(image_from_source.ROM_FIRMWARE_BUILTINS))
        for _name, handle in pairs:
            self.assertEqual(handle[0], TAG_CODE_OBJECT)

    def test_build_image_includes_rom_firmware_code(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "def managed_entry():\n"
            "    return sum(range(3))\n"
            "\n"
            "managed_entry()\n",
            "<rom-seed>",
        )
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)
        # Module + managed_entry + ROM firmware CODE_OBJECTs.
        self.assertGreaterEqual(
            len(result.code_handles),
            2 + len(image_from_source.ROM_FIRMWARE_BUILTINS),
        )
        self.assertGreaterEqual(len(image_from_source.ROM_FIRMWARE_BUILTINS), 8)
        self.assertGreater(len(result.program_slots), 0)


if __name__ == "__main__":
    unittest.main()
