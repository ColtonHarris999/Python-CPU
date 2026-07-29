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
                "def managed_entry():\n"
                "    import sys\n"
                "    return 0\n"
                "\n"
                "managed_entry()\n",
                "<unsupported>",
            )

        msg = str(ctx.exception)
        self.assertIn("Deferred opcode", msg)
        self.assertIn("IMPORT_NAME", msg)

    def test_load_attr_accepted_with_seed_instance(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "# pycore-inject: SEED_INSTANCE o slots=4\n"
            "def managed_entry():\n"
            "    o.x = 5\n"
            "    return o.x\n"
            "\n"
            "managed_entry()\n",
            "<attr-seed>",
        )
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)
        self.assertGreater(len(result.program_slots), 0)

    def test_function_defaults_folded_at_build_time(self) -> None:
        result = image_from_source.build_image_from_source_text(
            "def f(a, b=5):\n"
            "    return a + b\n"
            "\n"
            "def managed_entry():\n"
            "    return f(1)\n"
            "\n"
            "managed_entry()\n",
            "<defaults>",
        )
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)

    def test_set_function_attribute_closure_rejected(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "def managed_entry():\n"
                "    x = 1\n"
                "    def inner():\n"
                "        return x\n"
                "    return inner()\n"
                "\n"
                "managed_entry()\n",
                "<closure>",
            )

        msg = str(ctx.exception)
        self.assertTrue(
            "SET_FUNCTION_ATTRIBUTE" in msg
            or "LOAD_CLOSURE" in msg
            or "MAKE_CELL" in msg
            or "COPY_FREE_VARS" in msg
            or "Unsupported" in msg
            or "Deferred" in msg,
            msg,
        )

    def test_nop_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    x = 7\n"
            "    if False:\n"
            "        pass\n"
            "    return x\n"
            "\n"
            "managed_entry()\n"
        )

        # Dead `if False:` leaves NOP after CPython 3.14 peephole.
        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("NOP", opnames)

        result = image_from_source.build_image_from_source_text(src, "<nop>")
        self.assertGreater(len(result.program_slots), 0)

    def test_copy_opcode_now_supported(self) -> None:
        src = (
            "x = y = 5\n"
            "def managed_entry():\n"
            "    return x\n"
            "\n"
            "managed_entry()\n"
        )

        # `x = y = 5` emits COPY (duplicating the value for the second store).
        opnames = {
            ins.opname for ins in dis.get_instructions(_compile_module(src))
        }
        self.assertIn("COPY", opnames)

        # COPY was previously rejected by STACK_OP_REJECTS; it must now build.
        result = image_from_source.build_image_from_source_text(src, "<copy>")
        self.assertGreater(len(result.program_slots), 0)

    def test_swap_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    x = [1, 2]\n"
            "    x[0] += 5\n"
            "    return x[0]\n"
            "\n"
            "managed_entry()\n"
        )

        # `x[0] += 5` emits SWAP 3 / SWAP 2 before STORE_SUBSCR.
        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("SWAP", opnames)

        # SWAP was previously rejected by STACK_OP_REJECTS; it must now build.
        result = image_from_source.build_image_from_source_text(src, "<swap>")
        self.assertGreater(len(result.program_slots), 0)

    def test_delete_fast_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    x = 1\n"
            "    y = 2\n"
            "    del x\n"
            "    return y\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("DELETE_FAST", opnames)

        result = image_from_source.build_image_from_source_text(src, "<delete_fast>")
        self.assertGreater(len(result.program_slots), 0)

    def test_store_fast_load_fast_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    a = 9; return a + b\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("STORE_FAST_LOAD_FAST", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<store_fast_load_fast>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_load_fast_load_fast_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    a, b = b, a\n"
            "    return a\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("LOAD_FAST_LOAD_FAST", opnames)
        self.assertIn("STORE_FAST_STORE_FAST", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<load_fast_load_fast>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_load_fast_borrow_load_fast_borrow_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 3\n"
            "    b = 4\n"
            "    return a + b\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("LOAD_FAST_BORROW_LOAD_FAST_BORROW", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<load_fast_borrow_load_fast_borrow>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_load_fast_and_clear_opcode_now_supported(self) -> None:
        src = (
            "# pycore-inject: LOAD_FAST_AND_CLEAR managed_entry x\n"
            "\n"
            "def managed_entry():\n"
            "    x = 5\n"
            "    y = 2\n"
            "    z = x\n"
            "    return z + y\n"
            "\n"
            "managed_entry()\n"
        )

        module_code = compile(src, "<load_fast_and_clear>", "exec")
        injected = image_from_source.apply_lfac_injects(module_code, src)
        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(injected):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("LOAD_FAST_AND_CLEAR", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<load_fast_and_clear>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_load_fast_and_clear_inject_clears_source_slot(self) -> None:
        # Mirrors img_load_fast_and_clear_cleared.py: the inject rewrites the
        # first LOAD_FAST of `x` to LOAD_FAST_AND_CLEAR, and the following
        # `del x` emits DELETE_FAST on that same slot.  The clear-proof
        # depends on both opcodes being present over the same local.
        src = (
            "# pycore-inject: LOAD_FAST_AND_CLEAR managed_entry x\n"
            "\n"
            "def managed_entry():\n"
            "    x = 5\n"
            "    y = 2\n"
            "    z = x\n"
            "    del x\n"
            "    return z + y\n"
            "\n"
            "managed_entry()\n"
        )

        module_code = compile(src, "<lfac_cleared>", "exec")
        injected = image_from_source.apply_lfac_injects(module_code, src)
        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(injected):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("LOAD_FAST_AND_CLEAR", opnames)
        self.assertIn("DELETE_FAST", opnames)

        result = image_from_source.build_image_from_source_text(src, "<lfac_cleared>")
        self.assertGreater(len(result.program_slots), 0)

    def test_load_fast_check_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    cond = 1\n"
            "    if cond:\n"
            "        a = 7\n"
            "    return a\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("LOAD_FAST_CHECK", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<load_fast_check>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_to_bool_opcode_now_supported(self) -> None:
        # Mirrors img_to_bool.py: INT (0/nonzero), BOOL, and FLOAT (0.0/nonzero)
        # all flow through TO_BOOL, and a FLOAT constant must serialize.
        src = (
            "def managed_entry():\n"
            "    z = 0\n"
            "    n = 5\n"
            "    b = True\n"
            "    fz = 0.0\n"
            "    fnz = 2.5\n"
            "    out = 0\n"
            "    if z:\n"
            "        out += 1\n"
            "    if n:\n"
            "        out += 10\n"
            "    if b:\n"
            "        out += 100\n"
            "    if fz:\n"
            "        out += 1000\n"
            "    if fnz:\n"
            "        out += 10000\n"
            "    return out\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("TO_BOOL", opnames)

        result = image_from_source.build_image_from_source_text(src, "<to_bool>")
        self.assertGreater(len(result.program_slots), 0)

    def test_to_bool_string_tags_now_supported(self) -> None:
        # Mirrors img_to_bool_str.py. The final literal exceeds the 15-byte
        # SHORT_STR ceiling, so image serialization exercises LONG_STR too.
        src = (
            "def managed_entry():\n"
            "    empty = ''\n"
            "    short = 'hi'\n"
            "    long = 'this is a long string!!'\n"
            "    out = 0\n"
            "    if empty:\n"
            "        out += 100\n"
            "    if short:\n"
            "        out += 1\n"
            "    if long:\n"
            "        out += 10\n"
            "    return out\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("TO_BOOL", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<to_bool_strings>"
        )
        self.assertGreater(len(result.program_slots), 0)
        self.assertGreater(result.string_heap.next_addr, 0)

    def test_unary_not_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    z = 0\n"
            "    n = 5\n"
            "    t = True\n"
            "    f = False\n"
            "    a = not z\n"
            "    b = not n\n"
            "    c = not t\n"
            "    d = not f\n"
            "    out = 0\n"
            "    if a:\n"
            "        out += 1\n"
            "    if b:\n"
            "        out += 2\n"
            "    if c:\n"
            "        out += 4\n"
            "    if d:\n"
            "        out += 8\n"
            "    return out\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("UNARY_NOT", opnames)

        result = image_from_source.build_image_from_source_text(src, "<unary_not>")
        self.assertGreater(len(result.program_slots), 0)

    def test_is_op_opcode_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    t = True\n"
            "    f = False\n"
            "    n = None\n"
            "    m = None\n"
            "    x = []\n"
            "    one = 1\n"
            "    out = 0\n"
            "    if a is a:\n"
            "        out += 1\n"
            "    if a is not b:\n"
            "        out += 2\n"
            "    if t is f:\n"
            "        out += 4\n"
            "    if t is True:\n"
            "        out += 8\n"
            "    if n is m:\n"
            "        out += 16\n"
            "    if t is not one:\n"
            "        out += 32\n"
            "    if x is x:\n"
            "        out += 64\n"
            "    y = []\n"
            "    z = []\n"
            "    if y is not z:\n"
            "        out += 128\n"
            "    return out\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("IS_OP", opnames)

        result = image_from_source.build_image_from_source_text(src, "<is_op>")
        self.assertGreater(len(result.program_slots), 0)

    def test_compare_op_packed_forms_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 2\n"
            "    b = 3\n"
            "    r0 = a < b\n"
            "    r1 = a <= b\n"
            "    r2 = a == b\n"
            "    r3 = a != b\n"
            "    r4 = a > b\n"
            "    r5 = a >= b\n"
            "    out = 0\n"
            "    if a < b:\n"
            "        out += 1\n"
            "    if a <= b:\n"
            "        out += 2\n"
            "    if a == b:\n"
            "        out += 4\n"
            "    if a != b:\n"
            "        out += 8\n"
            "    if a > b:\n"
            "        out += 16\n"
            "    if a >= b:\n"
            "        out += 32\n"
            "    return out + r0 + r1 + r2 + r3 + r4 + r5\n"
            "\n"
            "managed_entry()\n"
        )

        compare_args: set[int] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            instructions = list(image_from_source.iter_raw_instructions(co))
            for index, ins in enumerate(instructions):
                if ins.opname != "COMPARE_OP":
                    continue
                compare_args.add(ins.arg)
                self.assertEqual(instructions[index + 1].opname, "CACHE")

        self.assertEqual(compare_args, image_from_source.SUPPORTED_COMPARE_ARGS)
        result = image_from_source.build_image_from_source_text(src, "<compare_op>")
        self.assertGreater(len(result.program_slots), 0)

    def test_compare_op_unknown_packed_form_rejected(self) -> None:
        module = _compile_module("def cmp(a, b):\n    return a < b\n")
        compare_code = next(co for co in module.co_consts if hasattr(co, "co_code"))
        compare = next(
            ins for ins in image_from_source.iter_raw_instructions(compare_code)
            if ins.opname == "COMPARE_OP"
        )
        malformed = bytearray(compare_code.co_code)
        malformed[compare.offset + 1] = 0
        compare_code = compare_code.replace(co_code=bytes(malformed))

        with self.assertRaisesRegex(ValueError, "Unsupported COMPARE_OP oparg 0"):
            image_from_source.validate_code_object(compare_code)

    def test_pop_jump_if_none_opcodes_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    n = None\n"
            "    x = 1\n"
            "    lst = []\n"
            "    out = 0\n"
            "    if n is None:\n"
            "        out += 1\n"
            "    if x is not None:\n"
            "        out += 2\n"
            "    if lst is not None:\n"
            "        out += 4\n"
            "    if x is None:\n"
            "        out += 8\n"
            "    return out\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertIn("POP_JUMP_IF_NONE", opnames)
        self.assertIn("POP_JUMP_IF_NOT_NONE", opnames)

        result = image_from_source.build_image_from_source_text(
            src, "<pop_jump_if_none>"
        )
        self.assertGreater(len(result.program_slots), 0)

    def test_for_iter_bundle_now_supported(self) -> None:
        src = (
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    xs = [a, b]\n"
            "    total = 0\n"
            "    for x in xs:\n"
            "        total += x\n"
            "    return total\n"
            "\n"
            "managed_entry()\n"
        )

        opnames: set[str] = set()
        for co in image_from_source.iter_code_objects(_compile_module(src)):
            opnames.update(ins.opname for ins in dis.get_instructions(co))
        self.assertTrue(
            {"GET_ITER", "FOR_ITER", "END_FOR", "POP_ITER"} <= opnames
        )

        result = image_from_source.build_image_from_source_text(src, "<for_iter>")
        self.assertGreater(len(result.program_slots), 0)

    def test_for_iter_type_trap_source_builds(self) -> None:
        src = (
            "def managed_entry():\n"
            "    total = 0\n"
            "    for value in 7:\n"
            "        total += value\n"
            "    return total\n"
            "\n"
            "managed_entry()\n"
        )

        result = image_from_source.build_image_from_source_text(
            src, "<for_iter_type_trap>"
        )
        self.assertGreater(len(result.program_slots), 0)

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


class ClassImageBuilderTest(unittest.TestCase):
    def test_fold_module_class_simple(self) -> None:
        src = (
            "class Point:\n"
            "    def set_x(self, v):\n"
            "        self.x = v\n"
            "    def get_x(self):\n"
            "        return self.x\n"
            "\n"
            "def managed_entry():\n"
            "    p = Point()\n"
            "    p.set_x(7)\n"
            "    return p.get_x()\n"
            "\n"
            "managed_entry()\n"
        )
        result = image_from_source.build_image_from_source_text(src, "<class-simple>")
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)
        # No LOAD_BUILD_CLASS left in the module image path.
        module_co = compile(src, "<class-simple>", "exec")
        folded, specs = image_from_source.fold_module_classes(module_co, src)
        self.assertEqual(len(specs), 1)
        self.assertEqual(specs[0].name, "Point")
        self.assertIn("set_x", specs[0].methods)
        self.assertIn("get_x", specs[0].methods)
        opnames = [
            ins.opname
            for ins in image_from_source.iter_raw_instructions(folded)
            if ins.opname != "CACHE"
        ]
        self.assertNotIn("LOAD_BUILD_CLASS", opnames)
        self.assertIn("NOP", opnames)

    def test_fold_staticmethod_and_const(self) -> None:
        src = (
            "class Util:\n"
            "    WSIZE = 8\n"
            "    @staticmethod\n"
            "    def add(a, b):\n"
            "        return a + b\n"
            "\n"
            "def managed_entry():\n"
            "    return Util.WSIZE + Util().add(1, 2)\n"
            "\n"
            "managed_entry()\n"
        )
        module_co = compile(src, "<class-static>", "exec")
        _folded, specs = image_from_source.fold_module_classes(module_co, src)
        self.assertEqual(len(specs), 1)
        self.assertEqual(specs[0].constants.get("WSIZE"), 8)
        self.assertIn("add", specs[0].static_methods)
        self.assertNotIn("add", specs[0].methods)
        result = image_from_source.build_image_from_source_text(src, "<class-static>")
        self.assertEqual(result.module_code[0], TAG_CODE_OBJECT)

    def test_reject_class_with_bases(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "class C(object):\n"
                "    pass\n"
                "\n"
                "def managed_entry():\n"
                "    return 0\n"
                "\n"
                "managed_entry()\n",
                "<class-bases>",
            )
        msg = str(ctx.exception)
        self.assertIn("bases", msg.lower())

    def test_reject_nested_class(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "def managed_entry():\n"
                "    class Inner:\n"
                "        pass\n"
                "    return 0\n"
                "\n"
                "managed_entry()\n",
                "<class-nested>",
            )
        self.assertIn("inside function", str(ctx.exception))

    def test_reject_classmethod(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            image_from_source.build_image_from_source_text(
                "class C:\n"
                "    @classmethod\n"
                "    def m(cls):\n"
                "        return 1\n"
                "\n"
                "def managed_entry():\n"
                "    return 0\n"
                "\n"
                "managed_entry()\n",
                "<class-classmethod>",
            )
        self.assertIn("classmethod", str(ctx.exception).lower())


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

        operators = ("<", "<=", "==", "!=", ">", ">=")
        expression_args: list[int] = []
        conditional_args: list[int] = []
        for operator in operators:
            namespace: dict[str, object] = {}
            exec(f"def cmp(a, b): return a {operator} b", namespace)
            compare = next(
                ins
                for ins in dis.get_instructions(
                    namespace["cmp"], show_caches=True
                )
                if ins.opname == "COMPARE_OP"
            )
            expression_args.append(compare.arg)
            self.assertEqual(dis.stack_effect(compare.opcode, compare.arg), -1)

            namespace = {}
            exec(
                f"def cmp(a, b):\n"
                f"    if a {operator} b:\n"
                f"        return 1\n"
                f"    return 0\n",
                namespace,
            )
            compare = next(
                ins
                for ins in dis.get_instructions(
                    namespace["cmp"], show_caches=True
                )
                if ins.opname == "COMPARE_OP"
            )
            conditional_args.append(compare.arg)
            self.assertEqual(dis.stack_effect(compare.opcode, compare.arg), -1)

        self.assertEqual(expression_args, [2, 42, 72, 103, 132, 172])
        self.assertEqual(conditional_args, [18, 58, 88, 119, 148, 188])
        self.assertEqual(
            {arg >> 5 for arg in expression_args + conditional_args},
            set(range(6)),
        )
        self.assertTrue(all((arg & 16) == 0 for arg in expression_args))
        self.assertTrue(all((arg & 16) != 0 for arg in conditional_args))


if __name__ == "__main__":
    unittest.main()
