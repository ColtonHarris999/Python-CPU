"""Host tests for native method dispatch seeding and firmware bodies."""

from __future__ import annotations

import dis
import pathlib
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("native method tests require Python 3.14")

from encoding import (
    NATIVE_METHOD_COUNT,
    NATIVE_METHOD_TABLE_ADDR,
    TAG_CODE_OBJECT,
    encode_short_string,
)
from image_from_source import (
    FIRMWARE_BUILTINS_DIR,
    ROM_NATIVE_METHODS,
    _ImageSerializer,
    _build_set_add_method_code,
    build_builtins_dict,
    build_image_from_source_text,
    validate_code_tree,
)
from run_image_test import host_entry_result


# Packed SHORT_STR values must match pycore_defs.svh PY_NMETH_NAME_* /
# PY_ATTR_NAME_ARGS.
_NAME_HEX = {
    "append": "6617070656e640000000000000000000",
    "pop": "3706f700000000000000000000000000",
    "extend": "6657874656e640000000000000000000",
    "clear": "5636c656172000000000000000000000",
    "add": "36164640000000000000000000000000",
    "update": "67570646174650000000000000000000",
    "join": "46a6f696e00000000000000000000000",
    "startswith": "a7374617274737769746800000000000",
    "endswith": "8656e647377697468000000000000000",
    "find": "466696e6400000000000000000000000",
    "rfind": "57266696e64000000000000000000000",
    "index": "5696e646578000000000000000000000",
    "rindex": "672696e6465780000000000000000000",
    "count": "5636f756e74000000000000000000000",
    "replace": "77265706c61636500000000000000000",
    "get": "36765740000000000000000000000000",
    "keys": "46b65797300000000000000000000000",
    "items": "56974656d73000000000000000000000",
    "values": "676616c7565730000000000000000000",
    "args": "46172677300000000000000000000000",
}


class NativeMethodNamePackTest(unittest.TestCase):
    def test_short_str_constants_match_rtl(self) -> None:
        for name, hex_val in _NAME_HEX.items():
            with self.subTest(name=name):
                self.assertEqual(f"{encode_short_string(name.encode()):032x}", hex_val)


class NativeMethodSeedTest(unittest.TestCase):
    def test_registry_covers_table(self) -> None:
        indexes = [i for i, _, _ in ROM_NATIVE_METHODS]
        self.assertEqual(sorted(indexes), list(range(NATIVE_METHOD_COUNT)))
        self.assertEqual(len(ROM_NATIVE_METHODS), 16)

    def test_firmware_sources_validate(self) -> None:
        for index, stem, func_name in ROM_NATIVE_METHODS:
            path = FIRMWARE_BUILTINS_DIR / f"{stem}.py"
            self.assertTrue(path.is_file(), path)
            source = path.read_text(encoding="utf-8")
            ns: dict[str, object] = {}
            exec(compile(source, str(path), "exec"), ns)
            func = ns[func_name]
            co = func.__code__
            if func_name == "set_add":
                co = _build_set_add_method_code(co)
            validate_code_tree(co)

    def test_set_add_device_body_emits_set_add(self) -> None:
        path = FIRMWARE_BUILTINS_DIR / "set_add.py"
        ns: dict[str, object] = {}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        co = _build_set_add_method_code(ns["set_add"].__code__)
        names = {ins.opname for ins in dis.get_instructions(co)}
        self.assertIn("SET_ADD", names)
        self.assertNotIn("LOAD_ATTR", names)

    def test_sidecar_written_with_code_objects(self) -> None:
        serializer = _ImageSerializer()
        build_builtins_dict(serializer)
        words = serializer.heap.words
        self.assertIn(NATIVE_METHOD_TABLE_ADDR, words)
        for i in range(NATIVE_METHOD_COUNT):
            addr = NATIVE_METHOD_TABLE_ADDR + i * 32
            self.assertEqual(words[addr + 16] & 0xF, TAG_CODE_OBJECT, i)


PROGRAM_GOLDENS = {
    "img_list_pop.py": 60,
    "img_list_pop_empty.py": 9,
    "img_str_methods.py": 331,
    "img_str_search_methods.py": 8191,
    "img_str_p5e_batch2.py": 268435455,
    "img_exc_args.py": 2,
    "img_try_syntaxerror_msg.py": 2,
    "img_list_methods.py": 10,
    "img_list_method_unbound.py": 7,
    "img_dict_methods.py": 16,
    "img_set_methods.py": 4,
}


class NativeMethodImageBuildTest(unittest.TestCase):
    def test_programs_build_and_host_golden(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        for fname, expect in PROGRAM_GOLDENS.items():
            with self.subTest(program=fname):
                path = root / fname
                text = path.read_text(encoding="utf-8")
                image = build_image_from_source_text(text, fname)
                self.assertGreater(len(image.program_slots), 0)
                self.assertEqual(host_entry_result(path, "managed_entry"), expect)

    def test_missing_method_program_builds(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "programs"
        path = root / "img_list_method_missing.py"
        image = build_image_from_source_text(
            path.read_text(encoding="utf-8"), path.name
        )
        self.assertGreater(len(image.program_slots), 0)


if __name__ == "__main__":
    unittest.main()
