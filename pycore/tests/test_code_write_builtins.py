"""Host stand-ins and encoding ids for the code-RAM writers (step C / W-5)."""

from __future__ import annotations

import pathlib
import re
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("code-write tests require Python 3.14")

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


class TestCodeWriteIds(unittest.TestCase):
    def test_bi_ids_match_rtl(self) -> None:
        self.assertEqual(encoding.BI_CODE_ALLOC, _rtl_bi("PY_BI_CODE_ALLOC"))
        self.assertEqual(encoding.BI_CODE_BLIT, _rtl_bi("PY_BI_CODE_BLIT"))
        self.assertEqual(encoding.BI_CODE_PATCH, _rtl_bi("PY_BI_CODE_PATCH"))
        self.assertEqual(encoding.BI_CODE_NEW, _rtl_bi("PY_BI_CODE_NEW"))
        self.assertEqual(encoding.BI_CODE_KIND, _rtl_bi("PY_BI_CODE_KIND"))
        self.assertEqual(encoding.BI_CODE_ALLOC, encoding.BI_EXEC_GLOBALS + 1)
        self.assertEqual(encoding.BI_CODE_NEW, encoding.BI_CODE_ALLOC + 3)
        self.assertEqual(encoding.BI_CODE_KIND, encoding.BI_CODE_NEW + 1)

    def test_seeded_as_native_builtins(self) -> None:
        from encoding import OBK_BUILTIN, int_value, ob_kind, obj_field_val_addr

        serializer = image_from_source._ImageSerializer()
        image_from_source.build_builtins_dict(serializer)
        found: set[int] = set()
        want = {
            encoding.BI_CODE_ALLOC,
            encoding.BI_CODE_BLIT,
            encoding.BI_CODE_PATCH,
            encoding.BI_CODE_NEW,
            encoding.BI_CODE_KIND,
        }
        words = serializer.heap.words
        for addr, head in words.items():
            if ob_kind(head) != OBK_BUILTIN:
                continue
            bid = words.get(obj_field_val_addr(addr, 0))
            if bid in {int_value(i) for i in want}:
                found.add(int(bid))
        self.assertEqual(found, {int_value(i) for i in want})


class TestCodeWriteHostStandins(unittest.TestCase):
    def test_new_call_returns_seven(self) -> None:
        ns = image_from_source.load_rom_firmware_callables()
        alloc = ns["_bi_code_alloc"]
        blit = ns["_bi_code_blit"]
        new = ns["_bi_code_new"]
        base = alloc(3)
        self.assertEqual(
            blit(
                base,
                [
                    (0 << 8) | 128,
                    (7 << 8) | 94,
                    (0 << 8) | 35,
                ],
            ),
            3,
        )
        fn = new([base, (), (), 1 << 32, (), (), {}, (), 0])
        self.assertEqual(fn(), 7)

    def test_patch_then_call_sees_new_word(self) -> None:
        ns = image_from_source.load_rom_firmware_callables()
        alloc = ns["_bi_code_alloc"]
        blit = ns["_bi_code_blit"]
        patch = ns["_bi_code_patch"]
        new = ns["_bi_code_new"]
        base = alloc(3)
        blit(base, [(0 << 8) | 128, (1 << 8) | 94, (0 << 8) | 35])
        fn = new([base, (), (), 1 << 32, (), (), {}, (), 0])
        self.assertEqual(fn(), 1)
        patch(base + 1, (7 << 8) | 94)
        self.assertEqual(fn(), 7)


class TestCodeKindHostStandin(unittest.TestCase):
    def test_kind_matches_encoding_tags(self) -> None:
        kind = image_from_source._host_code_kind
        self.assertEqual(kind(5), encoding.TAG_INT)
        self.assertEqual(kind("hi"), encoding.TAG_SHORT_STR)
        self.assertEqual(kind("0123456789abcdef"), encoding.TAG_LONG_STR)
        self.assertEqual(kind(True), encoding.TAG_BOOL)
        self.assertEqual(kind(None), encoding.TAG_CONTROL)

    def test_rom_eval_str_uses_firmware_compile(self) -> None:
        ns = image_from_source.load_rom_firmware_callables()
        self.assertEqual(ns["_bi_code_kind"]("1 + 2"), encoding.TAG_SHORT_STR)
        self.assertEqual(ns["eval"]("1 + 2"), 3)
        self.assertEqual(ns["eval"]("1 + 2 + 3 + 4 + 5"), 15)

    def test_rom_eval_code_object_still_calls(self) -> None:
        ns = image_from_source.load_rom_firmware_callables()
        co = ns["compile"]("1 + 2", "<s>", "eval")
        self.assertEqual(ns["_bi_code_kind"](co), encoding.TAG_CODE_OBJECT)
        self.assertEqual(ns["eval"](co), 3)
