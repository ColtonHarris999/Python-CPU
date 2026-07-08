"""Unit tests for the PyCore bytecode analyzer (pycore/tools/btanalyze)."""

from __future__ import annotations

import dis
import json
import os
import pathlib
import sys
import unittest


_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_TOOLS_DIR = _REPO_ROOT / "pycore" / "tools"
sys.path.insert(0, str(_TOOLS_DIR))

import preprocess  # noqa: E402
import analyze_bytecode  # noqa: E402
from btanalyze import gaps as gaps_mod  # noqa: E402
from btanalyze import report as report_mod  # noqa: E402
from btanalyze.cfg import build_cfg  # noqa: E402
from btanalyze.folds import analyze_folds  # noqa: E402
from btanalyze.targets import (  # noqa: E402
    derive_fold,
    derive_hw_class,
    load_target,
)

TARGET = load_target(_REPO_ROOT / "pycore" / "targets" / "pycore.json")
FIB = _REPO_ROOT / "pycore" / "programs" / "fib_iterative.py"
BUBBLE = _REPO_ROOT / "pycore" / "programs" / "bubble_sort.py"


def make_fn(src: str, name: str = "managed_entry"):
    namespace: dict = {}
    exec(compile(src, "<fixture>", "exec"), namespace)
    return namespace[name]


def load(path: pathlib.Path):
    return analyze_bytecode.load_function(path, "managed_entry")


def folds_by_name(fn) -> dict:
    cfg = build_cfg(fn)
    result = analyze_folds(cfg, TARGET)
    return {c.name: c for c in result.candidates}


def findings(fn, *, include_out_of_scope: bool = False):
    cfg = build_cfg(fn)
    return gaps_mod.analyze_gaps(
        fn, cfg, TARGET, include_out_of_scope=include_out_of_scope
    )


class CFGTest(unittest.TestCase):
    def test_fib_loop_detection(self) -> None:
        cfg = build_cfg(load(FIB))
        self.assertEqual(cfg.loop_count, 1)
        self.assertTrue(cfg.is_in_loop(28))  # loop body
        self.assertTrue(cfg.is_in_loop(14))  # loop header
        self.assertFalse(cfg.is_in_loop(2))  # prologue
        self.assertFalse(cfg.is_in_loop(74))  # return tail

    def test_blocks_partition_offsets(self) -> None:
        cfg = build_cfg(load(FIB))
        covered = {off for b in cfg.blocks for off in
                   (i.offset for i in cfg.block_instructions(b))}
        self.assertEqual(covered, {i.offset for i in cfg.instructions})


class FoldTest(unittest.TestCase):
    def test_fib_folds_and_maximal_munch(self) -> None:
        folds = folds_by_name(load(FIB))
        # F1 (SRC SRC RDX SNK) beats F2/F6 at the two expr-store sites.
        self.assertIn("F1-expr-store", folds)
        self.assertEqual(sorted(folds["F1-expr-store"].offsets), [28, 52])
        self.assertNotIn("F2-expr", folds)  # maximal munch took the longer F1
        self.assertNotIn("F6-chain-op", folds)
        # The loop condition folds to a full compare-and-branch.
        self.assertIn("F3-cmp-branch-full", folds)
        self.assertEqual(folds["F3-cmp-branch-full"].offsets, [14])
        self.assertIn("F4-move", folds)
        self.assertTrue(folds["F1-expr-store"].in_loop)

    def test_fib_fold_needs_ops(self) -> None:
        folds = folds_by_name(load(FIB))
        self.assertIn(
            "LOAD_FAST_BORROW_LOAD_FAST_BORROW",
            folds["F1-expr-store"].needs_ops,
        )

    def test_bubble_falls_back_to_f2_when_branch_unbuildable(self) -> None:
        # bubble_sort compares via LOAD_FAST_BORROW_LOAD_FAST_BORROW (reject), so
        # the requires_support F3 cannot emit; it must degrade to F2-expr.
        folds = folds_by_name(load(BUBBLE))
        self.assertIn("F2-expr", folds)
        self.assertIn(18, folds["F2-expr"].offsets)
        self.assertNotIn("F3-cmp-branch-full", folds)
        self.assertIn("F4-move", folds)


class GapTest(unittest.TestCase):
    def test_flagship_fused_load_is_error(self) -> None:
        result = findings(load(FIB))
        errors = [f for f in result.findings if f.severity == "error"]
        names = {f.opname for f in errors}
        self.assertIn("LOAD_FAST_BORROW_LOAD_FAST_BORROW", names)

    def test_compare_op_partial_warns(self) -> None:
        result = findings(load(FIB))
        warns = {f.opname for f in result.findings if f.severity == "warn"}
        self.assertIn("COMPARE_OP", warns)

    def test_partial_ops_warn_via_matrix(self) -> None:
        for opname in ("COPY", "SWAP"):
            info = TARGET.classify(opname)
            finding = gaps_mod._finding_for(
                info, offset=0, line=1, in_loop=False, include_out_of_scope=False
            )
            self.assertIsNotNone(finding)
            self.assertEqual(finding.severity, "warn")

    def test_costly_in_loop_is_hotspot(self) -> None:
        fn = make_fn(
            "def managed_entry():\n"
            "    n = 4\n"
            "    acc = 64\n"
            "    while n > 0:\n"
            "        acc = acc / 2\n"
            "        n = n - 1\n"
            "    return acc\n"
        )
        result = findings(fn)
        hotspots = [f for f in result.findings if f.severity == "hotspot"]
        self.assertTrue(hotspots)
        self.assertTrue(any(f.hw_class == "ALUN" for f in hotspots))

    def test_object_opcode_suppressed_by_default(self) -> None:
        fn = make_fn("def managed_entry():\n    return len\n")
        default = findings(fn)
        self.assertFalse(any(f.opname == "LOAD_GLOBAL" for f in default.findings))
        shown = findings(fn, include_out_of_scope=True)
        info = [f for f in shown.findings if f.opname == "LOAD_GLOBAL"]
        self.assertTrue(info)
        self.assertEqual(info[0].severity, "info")


class HwClassTest(unittest.TestCase):
    def test_target_matches_derivation(self) -> None:
        for opname, entry in TARGET.opcodes.items():
            self.assertEqual(
                entry["hw_class"], derive_hw_class(opname),
                f"hw_class mismatch for {opname}",
            )
            self.assertEqual(
                entry["fold"], derive_fold(opname),
                f"fold mismatch for {opname}",
            )

    def test_binary_op_per_arg_resolver(self) -> None:
        self.assertEqual(TARGET.classify("BINARY_OP", 0).hw_class, "ALU1")
        self.assertEqual(TARGET.classify("BINARY_OP", 11).hw_class, "ALUN")
        sub = TARGET.classify("BINARY_OP", 26)
        self.assertEqual(sub.hw_class, "OBJECT")
        self.assertEqual(sub.obj_group, "OBJ_SEQ")
        self.assertEqual(sub.fold, "BAR")
        self.assertEqual(TARGET.classify("BINARY_OP", 4).hw_class, "OBJECT")

    def test_load_global_is_infeasible_object(self) -> None:
        info = TARGET.classify("LOAD_GLOBAL")
        self.assertEqual(info.fit, "infeasible")
        self.assertTrue(info.suppress)
        self.assertEqual(info.obj_group, "OBJ_NS")


class ObjGroupTest(unittest.TestCase):
    def test_object_partition_is_exact(self) -> None:
        all_object = {n for n in dis.opmap if derive_hw_class(n) == "OBJECT"}
        union: set[str] = set()
        for group_name, group in TARGET.obj_groups.items():
            members = set(group["members"])
            self.assertTrue(union.isdisjoint(members), f"overlap in {group_name}")
            union |= members
            self.assertIn(group["distance"], range(1, 6))
        self.assertEqual(union, all_object)
        self.assertEqual(len(union), 88)
        self.assertNotIn("CALL", union)

    def test_roadmap_orders_by_distance(self) -> None:
        fn = make_fn(
            "def managed_entry(x, i):\n"
            "    y = x[i]\n"
            "    z = [y]\n"
            "    return z\n"
        )
        self.assertEqual(findings(fn).roadmap, [])
        roadmap = findings(fn, include_out_of_scope=True).roadmap
        groups = [item.obj_group for item in roadmap]
        self.assertEqual(groups, ["OBJ_SEQ", "OBJ_BUILD"])  # D1 before D2


class BacklogTest(unittest.TestCase):
    def test_swap_and_delete_are_backlog_items(self) -> None:
        swap = make_fn(
            "def managed_entry(a, b):\n    a, b = b, a\n    return a\n"
        )
        backlog = {b.opcode: b for b in findings(swap).backlog}
        for opcode in ("LOAD_FAST_LOAD_FAST", "STORE_FAST_STORE_FAST"):
            self.assertIn(opcode, backlog)
            self.assertNotEqual(backlog[opcode].fit, "infeasible")
            self.assertIsNotNone(backlog[opcode].needs_leaf)

        deleter = make_fn(
            "def managed_entry():\n    x = 1\n    del x\n    return 0\n"
        )
        del_backlog = {b.opcode for b in findings(deleter).backlog}
        self.assertIn("DELETE_FAST", del_backlog)


class TargetConsistencyTest(unittest.TestCase):
    def test_binary_args_match_preprocess(self) -> None:
        self.assertEqual(
            set(TARGET.opcodes["BINARY_OP"]["args"]["supported"]),
            set(preprocess.SUPPORTED_BINARY_ARGS),
        )

    def test_preprocess_supported_never_trap_or_reject(self) -> None:
        for opname in preprocess.SUPPORTED_OPS:
            if opname not in dis.opmap:
                continue  # stale entry (asserted separately)
            self.assertNotIn(
                TARGET.classify(opname).support, ("trap", "reject"),
                f"{opname} supported by preprocess but trap/reject in target",
            )

    def test_target_uses_only_real_opcodes(self) -> None:
        for opname in TARGET.opcodes:
            self.assertIn(opname, dis.opmap)

    def test_known_preprocess_drift(self) -> None:
        stale = {n for n in preprocess.SUPPORTED_OPS if n not in dis.opmap}
        self.assertEqual(
            stale,
            {"UNARY_POSITIVE", "JUMP_IF_TRUE_OR_POP", "JUMP_IF_FALSE_OR_POP"},
        )


class ProgramReportTest(unittest.TestCase):
    def test_program_report_summary(self) -> None:
        report = analyze_bytecode.analyze_program(FIB, "managed_entry", TARGET)
        self.assertEqual(report.summary.instruction_count, 26)
        self.assertEqual(report.summary.loop_count, 1)
        self.assertEqual(report.summary.max_stack_depth, 2)

    def test_json_output_is_stable(self) -> None:
        report = analyze_bytecode.analyze_program(FIB, "managed_entry", TARGET)
        payload = json.dumps(report_mod.to_dict(report), sort_keys=True)
        decoded = json.loads(payload)
        self.assertEqual(
            set(decoded),
            {"source", "function", "target", "summary", "folds",
             "findings", "backlog", "roadmap"},
        )
        self.assertEqual(
            set(decoded["summary"]),
            {"instruction_count", "coverage", "hw_class_histogram",
             "max_stack_depth", "loop_count", "finding_counts", "fold_site_count"},
        )

    def test_text_render_smoke(self) -> None:
        report = analyze_bytecode.analyze_program(FIB, "managed_entry", TARGET)
        text = report_mod.render_text(report, include_out_of_scope=True)
        self.assertIn("== Summary ==", text)
        self.assertIn("== Fold Candidates ==", text)
        self.assertIn("== Implement-Next Backlog ==", text)


if __name__ == "__main__":
    unittest.main()
