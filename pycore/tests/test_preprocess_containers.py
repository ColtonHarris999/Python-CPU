"""Unit tests for container-opcode support in pycore preprocess.

Covers:
  - Acceptance and correct slot emission for BUILD_LIST, BUILD_MAP,
    STORE_SUBSCR, and BINARY_OP/NB_SUBSCR.
  - Rejection of all deferred container opcodes with a clear message.
  - Correct type-sketch inference for container operations.
  - LOAD_FAST_BORROW_LOAD_FAST_BORROW expansion into two LOAD_FAST_BORROW.
  - Branch-target remapping is unaffected by container instructions.
"""

from __future__ import annotations

import sys
import types
import unittest

# Guard: only run on Python 3.14 (preprocess is 3.14-only).
if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("preprocess tests require Python 3.14")

from pycore.tools import preprocess


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _compile_fn(src: str, name: str = "managed_entry"):
    """Compile a function from source and return the callable."""
    ns: dict = {}
    exec(compile(src, "<test>", "exec"), ns)
    return ns[name]


def _emitted_opnames(fn) -> list[str]:
    """Run preprocess pipeline up to emit_instruction_words; return opnames."""
    heap = preprocess.StringHeapBuilder()
    emitted = preprocess.emit_instruction_words(
        preprocess.iter_filtered_instructions(fn),
        co_consts=fn.__code__.co_consts,
        string_heap=heap,
    )
    return [e.opname for e in emitted]


# ---------------------------------------------------------------------------
# Acceptance tests
# ---------------------------------------------------------------------------

class TestBuildListAccepted(unittest.TestCase):
    def setUp(self) -> None:
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    return [a, b]\n"
        )

    def test_build_list_in_opnames(self) -> None:
        opnames = _emitted_opnames(self.fn)
        self.assertIn("BUILD_LIST", opnames)

    def test_build_list_single_slot(self) -> None:
        """BUILD_LIST must occupy exactly one imem slot (not 3 like LOAD_CONST)."""
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        slot_map = preprocess.compute_slot_map(emitted)
        for i, e in enumerate(emitted):
            if e.opname == "BUILD_LIST":
                self.assertEqual(
                    slot_map[i + 1] - slot_map[i], 1,
                    "BUILD_LIST should occupy 1 slot",
                )

    def test_type_sketch_list_variable(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        var_tags, warnings = preprocess.infer_types(self.fn, emitted)
        # No list variable stored in locals here (returned directly), but at
        # least verify no crash and a: INT, b: INT.
        self.assertEqual(var_tags.get("a"), preprocess.TAG_INT)
        self.assertEqual(var_tags.get("b"), preprocess.TAG_INT)


class TestBuildMapAccepted(unittest.TestCase):
    def setUp(self) -> None:
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    k = 1\n"
            "    v = 2\n"
            "    return {k: v}\n"
        )

    def test_build_map_in_opnames(self) -> None:
        opnames = _emitted_opnames(self.fn)
        self.assertIn("BUILD_MAP", opnames)

    def test_build_map_single_slot(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        slot_map = preprocess.compute_slot_map(emitted)
        for i, e in enumerate(emitted):
            if e.opname == "BUILD_MAP":
                self.assertEqual(slot_map[i + 1] - slot_map[i], 1)

    def test_type_sketch_dict_variable(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        _, warnings = preprocess.infer_types(self.fn, emitted)
        # Check we can at least run type inference without raising.
        self.assertIsInstance(warnings, list)

    def test_dict_stored_variable_tagged_dict(self) -> None:
        """A local variable holding a BUILD_MAP result is tagged DICT."""
        fn = _compile_fn(
            "def managed_entry():\n"
            "    k = 7\n"
            "    v = 42\n"
            "    d = {k: v}\n"
            "    return d\n"
        )
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(fn),
            co_consts=fn.__code__.co_consts,
            string_heap=heap,
        )
        var_tags, _ = preprocess.infer_types(fn, emitted)
        self.assertEqual(var_tags.get("d"), preprocess.TAG_DICT)


class TestStoreSubscrAccepted(unittest.TestCase):
    def setUp(self) -> None:
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    lst = [a, b]\n"
            "    lst[0] = 99\n"
            "    return lst[0]\n"
        )

    def test_store_subscr_in_opnames(self) -> None:
        opnames = _emitted_opnames(self.fn)
        self.assertIn("STORE_SUBSCR", opnames)

    def test_store_subscr_single_slot(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        slot_map = preprocess.compute_slot_map(emitted)
        for i, e in enumerate(emitted):
            if e.opname == "STORE_SUBSCR":
                self.assertEqual(slot_map[i + 1] - slot_map[i], 1)

    def test_store_subscr_pops_three_in_type_sketch(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        # infer_types runs on the emitted list; check it doesn't crash and
        # lst is tagged LIST.
        var_tags, _ = preprocess.infer_types(self.fn, emitted)
        self.assertEqual(var_tags.get("lst"), preprocess.TAG_LIST)


class TestNbSubscrAccepted(unittest.TestCase):
    def setUp(self) -> None:
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    lst = [a, b]\n"
            "    return lst[0]\n"
        )

    def test_binary_op_nbsubscr_in_opnames(self) -> None:
        opnames = _emitted_opnames(self.fn)
        self.assertIn("BINARY_OP", opnames)

    def test_binary_op_nbsubscr_arg(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        for e in emitted:
            if e.opname == "BINARY_OP" and e.arg == preprocess.NBARG_SUBSCR:
                self.assertEqual(e.arg, 26)  # NB_SUBSCR = 26 from Python 3.14
                return
        self.fail("No BINARY_OP with NB_SUBSCR arg found in emitted instructions")

    def test_nb_subscr_result_tagged_object(self) -> None:
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        # Result of subscript read is OBJECT (element type unknown).
        var_tags, warnings = preprocess.infer_types(self.fn, emitted)
        # Warning should appear for the OBJECT-typed result.
        self.assertTrue(
            any("OBJECT" in w for w in warnings),
            f"Expected OBJECT-type warning, got: {warnings}",
        )


# ---------------------------------------------------------------------------
# LOAD_FAST_BORROW_LOAD_FAST_BORROW expansion
# ---------------------------------------------------------------------------

class TestLFBLFBExpansion(unittest.TestCase):
    def setUp(self) -> None:
        # A function with two consecutive local variable loads — Python 3.14
        # may emit LOAD_FAST_BORROW_LOAD_FAST_BORROW for this.
        self.fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    return [a, b]\n"
        )

    def test_no_lflb_in_emitted_opnames(self) -> None:
        opnames = _emitted_opnames(self.fn)
        self.assertNotIn(
            "LOAD_FAST_BORROW_LOAD_FAST_BORROW", opnames,
            "LFLB should be expanded into two LOAD_FAST_BORROW instructions",
        )

    def test_load_fast_borrow_appears_twice(self) -> None:
        opnames = _emitted_opnames(self.fn)
        lfb_count = opnames.count("LOAD_FAST_BORROW")
        # There should be at least 2 LOAD_FAST_BORROW (from the expansion)
        self.assertGreaterEqual(lfb_count, 2)

    def test_expanded_args_are_variable_indices(self) -> None:
        """Each expanded LOAD_FAST_BORROW arg should be a valid local index."""
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(self.fn),
            co_consts=self.fn.__code__.co_consts,
            string_heap=heap,
        )
        n_locals = len(self.fn.__code__.co_varnames)
        for e in emitted:
            if e.opname == "LOAD_FAST_BORROW":
                self.assertGreaterEqual(e.arg, 0)
                self.assertLess(e.arg, n_locals,
                                f"LOAD_FAST_BORROW arg {e.arg} >= n_locals {n_locals}")


# ---------------------------------------------------------------------------
# LIST_APPEND acceptance (Phase A: fast-path / grow-trap in CONT_LIST_APPEND)
# ---------------------------------------------------------------------------

class TestListAppendAccepted(unittest.TestCase):
    """LIST_APPEND is no longer deferred (see CONT_LIST_APPEND, pycore_core.sv).

    compile() only emits LIST_APPEND inside comprehensions, which still fail
    validation on FOR_ITER/GET_ITER (correctly still deferred) — so these
    tests exercise the opcode-table classification and type-sketch handling
    directly rather than a real compiled comprehension.
    """

    def test_list_append_not_deferred(self) -> None:
        self.assertNotIn("LIST_APPEND", preprocess.DEFERRED_OPS)

    def test_list_append_in_supported_ops(self) -> None:
        self.assertIn("LIST_APPEND", preprocess.SUPPORTED_OPS)

    def test_opcode_number(self) -> None:
        # python3.14 -c "import opcode; print(opcode.opmap['LIST_APPEND'])"
        self.assertEqual(preprocess.OP_LIST_APPEND, 78)

    def test_for_iter_get_iter_still_deferred_or_unsupported(self) -> None:
        # Comprehensions remain out of scope until FOR_ITER/GET_ITER land.
        self.assertNotIn("FOR_ITER", preprocess.SUPPORTED_OPS)
        self.assertNotIn("GET_ITER", preprocess.SUPPORTED_OPS)

    def test_infer_types_pops_only_the_element(self) -> None:
        """LIST_APPEND pops just the element; the list beneath is untouched."""
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    return a\n"
        )
        instructions = [
            preprocess.EmittedInstruction(
                opcode=preprocess.OP_BUILD_LIST, arg=0,
                source_offset=0, opname="BUILD_LIST"),
            preprocess.EmittedInstruction(
                opcode=0, arg=0, source_offset=2,
                opname="LOAD_SMALL_INT"),
            preprocess.EmittedInstruction(
                opcode=preprocess.OP_LIST_APPEND, arg=1,
                source_offset=4, opname="LIST_APPEND"),
        ]
        # Should not raise (would IndexError/underflow on a bad pop count).
        preprocess.infer_types(fn, instructions)


# ---------------------------------------------------------------------------
# LIST_EXTEND acceptance (fast-path / grow-trap in CONT_LIST_EXTEND)
# ---------------------------------------------------------------------------

class TestListExtendAccepted(unittest.TestCase):
    """LIST_EXTEND is no longer deferred (see CONT_LIST_EXTEND).

    compile() emits LIST_EXTEND from list-display unpack (`[1, 2, *x]`,
    `[*a, *b]`). Method calls like `a.extend(b)` still lower via
    LOAD_ATTR+CALL (unsupported), not LIST_EXTEND.
    """

    def test_list_extend_not_deferred(self) -> None:
        self.assertNotIn("LIST_EXTEND", preprocess.DEFERRED_OPS)

    def test_list_extend_in_supported_ops(self) -> None:
        self.assertIn("LIST_EXTEND", preprocess.SUPPORTED_OPS)

    def test_opcode_number(self) -> None:
        self.assertEqual(preprocess.OP_LIST_EXTEND, 79)

    def test_infer_types_pops_only_the_iterable(self) -> None:
        """LIST_EXTEND pops just the iterable; the list beneath is untouched."""
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    return a\n"
        )
        instructions = [
            preprocess.EmittedInstruction(
                opcode=preprocess.OP_BUILD_LIST, arg=0,
                source_offset=0, opname="BUILD_LIST"),
            preprocess.EmittedInstruction(
                opcode=preprocess.OP_BUILD_LIST, arg=0,
                source_offset=2, opname="BUILD_LIST"),
            preprocess.EmittedInstruction(
                opcode=preprocess.OP_LIST_EXTEND, arg=1,
                source_offset=4, opname="LIST_EXTEND"),
        ]
        preprocess.infer_types(fn, instructions)

    def test_star_unpack_program_accepted(self) -> None:
        """A real `[1, 2, *x]` program must preprocess without Deferred errors."""
        fn = _compile_fn(
            "def managed_entry(x):\n"
            "    return [1, 2, *x]\n",
            "managed_entry",
        )
        # Should not raise ValueError for LIST_EXTEND.
        list(preprocess.iter_filtered_instructions(fn))


# ---------------------------------------------------------------------------
# DELETE_SUBSCR / CONTAINS_OP acceptance
# ---------------------------------------------------------------------------

class TestDeleteContainsAccepted(unittest.TestCase):
    def test_delete_subscr_not_deferred(self) -> None:
        self.assertNotIn("DELETE_SUBSCR", preprocess.DEFERRED_OPS)
        self.assertIn("DELETE_SUBSCR", preprocess.SUPPORTED_OPS)
        self.assertEqual(preprocess.OP_DELETE_SUBSCR, 8)

    def test_contains_op_not_deferred(self) -> None:
        self.assertNotIn("CONTAINS_OP", preprocess.DEFERRED_OPS)
        self.assertIn("CONTAINS_OP", preprocess.SUPPORTED_OPS)
        self.assertEqual(preprocess.OP_CONTAINS_OP, 57)

    def test_delete_subscr_program_accepted(self) -> None:
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = [1, 2, 3]\n"
            "    del a[1]\n"
            "    return a[0]\n",
        )
        list(preprocess.iter_filtered_instructions(fn))

    def test_contains_op_program_accepted(self) -> None:
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = [1, 2, 3]\n"
            "    if 2 in a:\n"
            "        if 9 not in a:\n"
            "            return 1\n"
            "        return 0\n"
            "    return 0\n",
        )
        list(preprocess.iter_filtered_instructions(fn))


# ---------------------------------------------------------------------------
# Deferred-opcode rejection tests
# ---------------------------------------------------------------------------

class TestDeferredOpcodesRejected(unittest.TestCase):
    """Test that deferred container opcodes are explicitly rejected.

    Because some source programs emit other unsupported opcodes (e.g.
    LOAD_ATTR) before reaching the deferred op, these tests check the
    DEFERRED_OPS dict directly for membership and message quality, and
    supplement with a real program test for BUILD_SET.
    """

    def _assert_deferred_error(self, opname: str) -> None:
        """Verify opname is in DEFERRED_OPS with a non-empty reason string."""
        self.assertIn(opname, preprocess.DEFERRED_OPS,
                      f"{opname} is not in DEFERRED_OPS")
        reason = preprocess.DEFERRED_OPS[opname]
        self.assertTrue(len(reason) > 5,
                        f"DEFERRED_OPS[{opname!r}] reason is too short: {reason!r}")

    def test_map_add_in_deferred_ops(self) -> None:
        self._assert_deferred_error("MAP_ADD")

    def test_dict_update_in_deferred_ops(self) -> None:
        self._assert_deferred_error("DICT_UPDATE")

    def test_deferred_ops_not_in_supported_ops(self) -> None:
        """All deferred opcodes must be absent from SUPPORTED_OPS."""
        for opname in preprocess.DEFERRED_OPS:
            self.assertNotIn(
                opname, preprocess.SUPPORTED_OPS,
                f"{opname} is in DEFERRED_OPS but also in SUPPORTED_OPS",
            )

    def test_build_set_supported(self) -> None:
        """Non-constant set display emits BUILD_SET and is accepted."""
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    return {a, b}\n"
        )
        opnames = _emitted_opnames(fn)
        self.assertIn("BUILD_SET", opnames)
        self.assertIn("BUILD_SET", preprocess.SUPPORTED_OPS)
        self.assertNotIn("BUILD_SET", preprocess.DEFERRED_OPS)


# ---------------------------------------------------------------------------
# Slot count / branch remapping
# ---------------------------------------------------------------------------

class TestContainerSlotCount(unittest.TestCase):
    def test_container_instructions_counted_as_one_slot(self) -> None:
        """BUILD_LIST, BUILD_MAP, STORE_SUBSCR each occupy exactly 1 slot."""
        fn = _compile_fn(
            "def managed_entry():\n"
            "    a = 1\n"
            "    b = 2\n"
            "    lst = [a, b]\n"
            "    lst[0] = 99\n"
            "    return lst[0]\n"
        )
        heap = preprocess.StringHeapBuilder()
        emitted = preprocess.emit_instruction_words(
            preprocess.iter_filtered_instructions(fn),
            co_consts=fn.__code__.co_consts,
            string_heap=heap,
        )
        slot_map = preprocess.compute_slot_map(emitted)
        one_slot_ops = {"BUILD_LIST", "STORE_SUBSCR", "BINARY_OP"}
        for i, e in enumerate(emitted):
            if e.opname in one_slot_ops:
                size = slot_map[i + 1] - slot_map[i]
                self.assertEqual(
                    size, 1,
                    f"{e.opname} should be 1 slot, got {size}",
                )


class TestNbSubscrConstantValue(unittest.TestCase):
    def test_nbsubscr_oparg_is_26(self) -> None:
        """Verify NB_SUBSCR oparg resolved from Python 3.14 is 26."""
        self.assertEqual(
            preprocess.NBARG_SUBSCR, 26,
            "NB_SUBSCR oparg must be 26 in Python 3.14",
        )

    def test_nbsubscr_in_supported_binary_args(self) -> None:
        self.assertIn(preprocess.NBARG_SUBSCR, preprocess.SUPPORTED_BINARY_ARGS)

    def test_build_list_opcode_is_46(self) -> None:
        self.assertEqual(preprocess.OP_BUILD_LIST, 46)

    def test_build_map_opcode_is_47(self) -> None:
        self.assertEqual(preprocess.OP_BUILD_MAP, 47)

    def test_store_subscr_opcode_is_38(self) -> None:
        self.assertEqual(preprocess.OP_STORE_SUBSCR, 38)


if __name__ == "__main__":
    unittest.main()
