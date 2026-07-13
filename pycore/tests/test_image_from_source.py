"""Unit tests for the CPython image-boot source pipeline."""

from __future__ import annotations

import dis
import opcode
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("image_from_source tests require Python 3.14")

from encoding import TAG_CODE_OBJECT
from pycore.tools import image_from_source


def _compile_module(src: str):
    return compile(src, "<test-image>", "exec")


class ImageTranscodingTest(unittest.TestCase):
    def test_transcoding_preserves_raw_unit_count(self) -> None:
        code = _compile_module(
            "def managed_entry():\n"
            "    return 42\n"
            "\n"
            "managed_entry()\n"
        )

        for co in image_from_source.iter_code_objects(code):
            slots = image_from_source.transcode_code_units(co)
            self.assertEqual(len(slots), len(co.co_code) // 2)

    def test_nested_code_objects_serialize(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "def helper(x):\n"
            "    return x + 1\n"
            "\n"
            "def managed_entry():\n"
            "    return helper(41)\n"
            "\n"
            "managed_entry()\n",
            "<nested>",
        )

        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)
        self.assertGreaterEqual(len(result.code_handles), 3)
        self.assertGreater(len(result.program_slots), 0)

    def test_unsupported_opcode_rejected_clearly(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "def managed_entry(x):\n"
                "    return x.attr\n"
                "\n"
                "managed_entry(0)\n",
                "<unsupported>",
            )

        msg = str(ctx.exception)
        self.assertIn("Unsupported opcode", msg)
        self.assertIn("LOAD_ATTR", msg)

    def test_set_function_attribute_rejected_specifically(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "def managed_entry(x=1):\n"
                "    return x\n"
                "\n"
                "managed_entry()\n",
                "<defaults>",
            )

        msg = str(ctx.exception)
        self.assertIn("SET_FUNCTION_ATTRIBUTE", msg)
        self.assertIn("defaults", msg)
        self.assertIn("closures", msg)

    def test_globals_dict_pre_sizing_counts_distinct_stores(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "a = 1\n"
            "b = 2\n"
            "a = 3\n"
            "def managed_entry():\n"
            "    return a + b\n"
            "\n"
            "managed_entry()\n",
            "<globals>",
        )

        # Distinct STORE_NAME names: a, b, managed_entry.
        self.assertEqual(result.global_store_count, 3)
        self.assertEqual(result.globals_slot_count, 8)
        globals_addr = result.globals_dict[1]
        globals_header = result.heap.words[globals_addr]
        self.assertEqual(globals_header >> 64, 8)


class CPython314ConventionProbeTest(unittest.TestCase):
    def test_opcode_numbers_used_by_image_decode(self) -> None:
        self.assertEqual(opcode.opmap["PUSH_NULL"], 33)
        self.assertEqual(opcode.opmap["CALL"], 52)
        self.assertEqual(opcode.opmap["LOAD_GLOBAL"], 92)
        self.assertEqual(opcode.opmap["COMPARE_OP"], 56)

    def test_load_global_namei_and_null_bit(self) -> None:
        def f(x):
            return len([x])

        load_global = next(
            ins for ins in dis.get_instructions(f, show_caches=True)
            if ins.opname == "LOAD_GLOBAL"
        )

        self.assertEqual(load_global.arg >> 1, f.__code__.co_names.index("len"))
        self.assertEqual(load_global.arg & 1, 1)
        self.assertIn("NULL", load_global.argrepr)

    def test_module_call_layout_uses_push_null_before_call(self) -> None:
        code = _compile_module(
            "def managed_entry():\n"
            "    return 7\n"
            "\n"
            "managed_entry()\n"
        )
        opnames = [ins.opname for ins in dis.get_instructions(code, show_caches=True)]
        load_name_idx = opnames.index("LOAD_NAME")

        self.assertEqual(opnames[load_name_idx + 1], "PUSH_NULL")
        self.assertEqual(opnames[load_name_idx + 2], "CALL")

    def test_call_argc_and_compare_op_bit_layout(self) -> None:
        def f(x):
            return len([x])

        call = next(
            ins for ins in dis.get_instructions(f, show_caches=True)
            if ins.opname == "CALL"
        )
        self.assertEqual(call.arg, 1)

        def cmp(a, b):
            return a < b

        compare = next(
            ins for ins in dis.get_instructions(cmp, show_caches=True)
            if ins.opname == "COMPARE_OP"
        )
        self.assertEqual(compare.arg >> 5, 0)
        self.assertEqual(compare.arg & 0x1F, 2)


if __name__ == "__main__":
    unittest.main()
