"""Host tests for per-frame globals / _bi_exec_globals (Plan 1 P4)."""

from __future__ import annotations

import inspect
import pathlib
import re
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("exec-globals tests require Python 3.14")

import encoding
from pycore.tools import image_from_source

RTL_DEFS = (
    pathlib.Path(__file__).resolve().parents[1] / "rtl" / "pycore_defs.svh"
)


def _rtl_bi(name: str) -> int:
    text = RTL_DEFS.read_text(encoding="utf-8")
    m = re.search(
        rf"^localparam\s+logic\s*\[31:0\]\s+{name}\s*=\s*32'd([0-9]+);",
        text,
        re.MULTILINE,
    )
    if m is None:
        raise AssertionError(f"{name} not found in {RTL_DEFS}")
    return int(m.group(1))


class TestExecGlobalsIds(unittest.TestCase):
    def test_bi_exec_globals_matches_rtl(self):
        self.assertEqual(encoding.BI_EXEC_GLOBALS, _rtl_bi("PY_BI_EXEC_GLOBALS"))
        self.assertEqual(encoding.BI_EXEC_GLOBALS, encoding.BI_CODE_RELEASE + 1)

    def test_seeded_as_native_builtin(self):
        from encoding import OBK_BUILTIN, int_value, ob_kind, obj_field_val_addr

        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer)
        found = False
        for addr, head in serializer.heap.words.items():
            if ob_kind(head) != OBK_BUILTIN:
                continue
            if serializer.heap.words.get(obj_field_val_addr(addr, 0)) == int_value(
                encoding.BI_EXEC_GLOBALS
            ):
                found = True
                break
        self.assertTrue(found, "OBK_BUILTIN(BI_EXEC_GLOBALS) missing from builtins")

    def test_firmware_exec_signature(self):
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "exec.py"
        ns: dict[str, object] = {}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        fn = ns["exec"]
        self.assertEqual(inspect.getfullargspec(fn).args, ["code", "globals"])
        self.assertEqual(fn.__defaults__, (None,))
        image_from_source.validate_code_tree(fn.__code__)
        self.assertIn("_bi_exec_globals", fn.__code__.co_names)

    def test_firmware_eval_signature(self):
        path = image_from_source.FIRMWARE_BUILTINS_DIR / "eval.py"
        ns: dict[str, object] = {}
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), ns)
        fn = ns["eval"]
        self.assertEqual(inspect.getfullargspec(fn).args, ["code", "globals"])
        self.assertEqual(fn.__defaults__, (None,))
        image_from_source.validate_code_tree(fn.__code__)
        self.assertIn("_bi_exec_globals", fn.__code__.co_names)


if __name__ == "__main__":
    unittest.main()
