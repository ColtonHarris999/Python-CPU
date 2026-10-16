"""Frozen .mpy prelude, const pool, and flash image from the pinned mpy-cross."""

import unittest
from pathlib import Path

from mpy_image import (
    compile_file,
    disassemble,
    format_function,
    layout_flash,
    load_mpy,
    parse_flash,
    qstr_name,
)

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "mpycore" / "programs" / "prelude_kinds.py"


def _ops(raw):
    return [(inst["op"], inst.get("name"), inst["arg"]) for inst in disassemble(raw)]


class ImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile

        cls._tmp = tempfile.TemporaryDirectory()
        output = Path(cls._tmp.name) / "prelude_kinds.mpy"
        compile_file(SOURCE, output)
        cls.module = load_mpy(output.read_bytes())
        cls.text = format_function(cls.module, cls.module["raw"])

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _child(self, name):
        for child in self.module["raw"]["children"]:
            if qstr_name(self.module["qstrs"], child["prelude"]["simple_name"]) == name:
                return child
        self.fail(f"missing function {name}\n{self.text}")

    def test_module_body_and_plain_function(self):
        module = self.module["raw"]["prelude"]
        self.assertEqual(module["n_pos_args"], 0)
        self.assertEqual(module["n_def_pos_args"], 0)
        self.assertEqual(module["n_exc_stack"], 0)
        self.assertGreaterEqual(module["n_state"], 1)
        function = self._child("f")
        self.assertEqual(function["prelude"]["n_pos_args"], 0)
        self.assertGreaterEqual(function["prelude"]["n_state"], 2)
        self.assertEqual(
            _ops(function),
            [
                ("MP_BC_LOAD_CONST_SMALL_INT", None, 1),
                ("MP_BC_STORE_FAST", None, 0),
                ("MP_BC_LOAD_CONST_SMALL_INT", None, 2),
                ("MP_BC_STORE_FAST", None, 1),
                ("MP_BC_LOAD_FAST", None, 0),
                ("MP_BC_LOAD_FAST", None, 1),
                ("MP_BC_BINARY_OP", "MP_BINARY_OP_ADD", 27),
                ("MP_BC_RETURN_VALUE", None, None),
            ],
        )

    def test_function_with_defaults(self):
        function = self._child("g")
        prelude = function["prelude"]
        self.assertEqual(prelude["n_pos_args"], 1)
        self.assertEqual(prelude["n_def_pos_args"], 1)
        self.assertEqual(_ops(function)[-1][0], "MP_BC_RETURN_VALUE")
        module_ops = [inst["op"] for inst in disassemble(self.module["raw"])]
        self.assertIn("MP_BC_MAKE_FUNCTION_DEFARGS", module_ops)
        self.assertEqual(self.module["consts"], [])

    def test_signed_small_int(self):
        self.assertEqual(_ops(self._child("big"))[0], ("MP_BC_LOAD_CONST_SMALL_INT", None, 1000))
        self.assertEqual(_ops(self._child("neg"))[0], ("MP_BC_LOAD_CONST_SMALL_INT", None, -1000))

    def test_flash_image_round_trip(self):
        parsed = parse_flash(layout_flash(self.module))
        self.assertEqual(parsed["qstrs"], self.module["qstrs"])
        self.assertEqual(parsed["consts"], [])
        self.assertEqual(parsed["mpy_version"], 6)
        self.assertEqual(parsed["small_int_bits"], 31)
        functions = [self.module["raw"], *self.module["raw"]["children"]]
        self.assertEqual(
            [item["fun_data"] for item in parsed["functions"]],
            [item["fun_data"] for item in functions],
        )
        self.assertEqual(
            parsed["functions"][0]["children"],
            list(range(1, len(parsed["functions"]))),
        )
        print(self.text)


if __name__ == "__main__":
    unittest.main()
