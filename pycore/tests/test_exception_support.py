"""Exception-type catalog and OBJ_EXC opcode-tracking invariants."""

from __future__ import annotations

import builtins
import pathlib
import sys
import unittest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_TOOLS_DIR = _REPO_ROOT / "pycore" / "tools"
sys.path.insert(0, str(_TOOLS_DIR))

from btanalyze import gaps as gaps_mod  # noqa: E402
from btanalyze.targets import load_target  # noqa: E402

TARGET = load_target(_REPO_ROOT / "pycore" / "targets" / "pycore.json")
EXC_DOC = _REPO_ROOT / "pycore" / "docs" / "exception_support.md"
BC_DOC = _REPO_ROOT / "pycore" / "docs" / "bytecode_support.md"


def _builtin_exception_names() -> set[str]:
    names = {"EnvironmentError", "IOError", "WindowsError"}
    stack = [BaseException]
    seen: set[type] = set()
    while stack:
        cls = stack.pop()
        if cls in seen:
            continue
        seen.add(cls)
        names.add(cls.__name__)
        for sub in cls.__subclasses__():
            if sub.__module__ == "builtins":
                stack.append(sub)
    return names


class ExceptionCatalogTest(unittest.TestCase):
    def test_wave_a_types_are_seeded(self) -> None:
        import image_from_source as image_src
        seeded = sorted(
            name for name, row in TARGET.exceptions.items()
            if row["status"] == "seeded"
        )
        expected = sorted(name for name, _ in image_src.WAVE_A_EXCEPTION_TYPES)
        self.assertEqual(seeded, expected)
        row = TARGET.exceptions["StopIteration"]
        self.assertEqual(row["tp_base_actual"], "Exception")
        self.assertEqual(row["match"], "mro")
        self.assertEqual(row["construct"], "raise-type")

    def test_matching_parents_are_seeded(self) -> None:
        for name, parent in (("BaseException", None), ("Exception", "BaseException")):
            row = TARGET.exceptions[name]
            self.assertEqual(row["status"], "seeded")
            self.assertEqual(row["tp_base_actual"], parent)
            self.assertEqual(row["match"], "mro")
            self.assertEqual(row["seed_track"], "T1")

    def test_catalog_covers_builtin_exception_tree(self) -> None:
        self.assertEqual(set(TARGET.exceptions), _builtin_exception_names())

    def test_seeded_types_exist_in_builtins(self) -> None:
        self.assertTrue(hasattr(builtins, "StopIteration"))

    def test_wave_a_seed_tracks(self) -> None:
        wave_a = [
            name for name, row in TARGET.exceptions.items()
            if row.get("wave") == "A" and name not in (
                "BaseException", "Exception", "StopIteration",
            )
        ]
        self.assertEqual(
            sorted(wave_a),
            [
                "ArithmeticError",
                "AssertionError",
                "AttributeError",
                "IndexError",
                "KeyError",
                "LookupError",
                "NameError",
                "RuntimeError",
                "TypeError",
                "UnboundLocalError",
                "ValueError",
                "ZeroDivisionError",
            ],
        )
        for name in wave_a:
            self.assertEqual(TARGET.exceptions[name]["seed_track"], "T5-A")

    def test_trap_map_types_are_wave_a(self) -> None:
        expected = {
            "TypeError": ["PY_TRAP_TYPE"],
            "AttributeError": ["PY_TRAP_ATTR_ERROR"],
            "ZeroDivisionError": ["PY_TRAP_DIV_ZERO"],
        }
        for name, traps in expected.items():
            self.assertEqual(TARGET.exceptions[name]["trap_map"], traps)
            self.assertEqual(TARGET.exceptions[name]["seed_track"], "T5-A")

    def test_human_doc_mentions_every_catalog_type(self) -> None:
        text = EXC_DOC.read_text(encoding="utf-8")
        missing = [
            name for name in TARGET.exceptions
            if f"`{name}`" not in text
        ]
        self.assertEqual(missing, [])

    def test_human_doc_inventory_counts_match_json(self) -> None:
        from collections import Counter
        counts = Counter(row["status"] for row in TARGET.exceptions.values())
        text = EXC_DOC.read_text(encoding="utf-8")
        for status, n in counts.items():
            self.assertRegex(
                text,
                rf"\| `{status}` \| {n} \|",
                f"exception_support.md inventory missing {status}={n}",
            )


class ExceptionOpcodeTrackingTest(unittest.TestCase):
    def test_obj_exc_members_are_listed_opcodes(self) -> None:
        members = TARGET.obj_groups["OBJ_EXC"]["members"]
        missing = [m for m in members if m not in TARGET.opcodes]
        self.assertEqual(missing, [])

    def test_handler_opcodes_landed_or_partial(self) -> None:
        self.assertEqual(TARGET.opcodes["PUSH_EXC_INFO"]["support"], "execute")
        self.assertEqual(TARGET.opcodes["POP_EXCEPT"]["support"], "execute")
        self.assertEqual(TARGET.opcodes["RERAISE"]["support"], "execute")
        self.assertEqual(TARGET.opcodes["RAISE_VARARGS"]["support"], "partial")
        self.assertEqual(TARGET.opcodes["CHECK_EXC_MATCH"]["support"], "execute")
        self.assertEqual(TARGET.opcodes["RAISE_VARARGS"]["supported_opargs"], [1])
        self.assertEqual(TARGET.opcodes["RERAISE"]["supported_opargs"], [0, 1])

    def test_raise_oparg_ceiling(self) -> None:
        ok = TARGET.classify("RAISE_VARARGS", 1)
        bad = TARGET.classify("RAISE_VARARGS", 0)
        self.assertTrue(ok.arg_supported)
        self.assertFalse(bad.arg_supported)

    def test_raise_partial_is_warn_when_in_scope(self) -> None:
        info = TARGET.classify("RAISE_VARARGS", 1)
        hidden = gaps_mod._finding_for(
            info, offset=0, line=1, in_loop=False, include_out_of_scope=False,
        )
        shown = gaps_mod._finding_for(
            info, offset=0, line=1, in_loop=False, include_out_of_scope=True,
        )
        self.assertIsNone(hidden)
        self.assertIsNotNone(shown)
        assert shown is not None
        self.assertEqual(shown.severity, "warn")
        self.assertEqual(shown.support, "partial")

    def test_compiler_pseudo_ops_are_trap_never(self) -> None:
        for name in (
            "SETUP_FINALLY", "SETUP_WITH", "SETUP_CLEANUP", "POP_BLOCK",
        ):
            self.assertEqual(TARGET.opcodes[name]["support"], "trap")
            self.assertEqual(TARGET.opcodes[name]["plan_track"], "never")

    def test_bytecode_doc_inventory_counts_match_json(self) -> None:
        from collections import Counter
        counts = Counter(row["support"] for row in TARGET.opcodes.values())
        text = BC_DOC.read_text(encoding="utf-8")
        for support, n in counts.items():
            self.assertRegex(
                text,
                rf"\| `{support}` \| {n} \|",
                f"bytecode_support.md inventory missing {support}={n}",
            )

    def test_deferred_setup_finally_message_is_not_stale(self) -> None:
        import image_from_source as image_src
        msg = image_src.DEFERRED_OPS["SETUP_FINALLY"]
        self.assertNotIn("exception handling is deferred", msg)
        self.assertIn("pseudo-op", msg)


class WaveABootSeedTest(unittest.TestCase):
    def test_wave_a_tp_base_chain_and_exc_flag(self) -> None:
        from encoding import (
            CTL_NONE,
            ITER_EXHAUST_TYPE_ADDR,
            OB_FLAG_EXC_TYPE,
            OBK_TYPE,
            TAG_CONTROL,
            TAG_OBJECT,
            ob_flags,
            ob_kind,
            obj_field_tag_addr,
            obj_field_val_addr,
            tag_constant,
        )
        import image_from_source as image_src

        serializer = image_src._ImageSerializer()
        image_src.build_builtins_dict(serializer)
        words = serializer.heap.words
        string_heap = serializer.string_heap

        by_name: dict[str, int] = {}
        for addr, head in words.items():
            if ob_kind(head) != OBK_TYPE:
                continue
            name_val = words.get(obj_field_val_addr(addr, 2))
            name_tag = words.get(obj_field_tag_addr(addr, 2))
            if name_val is None or name_tag is None:
                continue
            name_tag &= 0xF
            for name, _ in image_src.WAVE_A_EXCEPTION_TYPES:
                expected = tag_constant(name, string_heap)
                if name_tag == expected[0] and name_val == expected[1]:
                    by_name[name] = addr
                    break

        expected = {name for name, _ in image_src.WAVE_A_EXCEPTION_TYPES}
        self.assertEqual(set(by_name), expected)

        sidecar = words[ITER_EXHAUST_TYPE_ADDR] & ((1 << 64) - 1)
        self.assertEqual(sidecar, by_name["StopIteration"])

        for name, parent in image_src.WAVE_A_EXCEPTION_TYPES:
            addr = by_name[name]
            self.assertEqual(ob_flags(words[addr]) & OB_FLAG_EXC_TYPE, OB_FLAG_EXC_TYPE)
            base_tag = words[obj_field_tag_addr(addr, 1)] & 0xF
            base_val = words[obj_field_val_addr(addr, 1)]
            if parent is None:
                self.assertEqual(base_tag, TAG_CONTROL)
                self.assertEqual(base_val & 0xF, CTL_NONE)
            else:
                self.assertEqual(base_tag, TAG_OBJECT)
                self.assertEqual(base_val & ((1 << 64) - 1), by_name[parent])


if __name__ == "__main__":
    unittest.main()
