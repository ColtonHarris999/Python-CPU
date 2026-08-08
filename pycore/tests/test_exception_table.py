"""Unit tests for CPython exception-table parsing and slot conversion."""

from __future__ import annotations

import dis
import sys
import unittest

if sys.version_info[:2] != (3, 14):
    raise unittest.SkipTest("exception table tests require Python 3.14")

from pycore.tools import exception_table


def _function_code(source: str):
    return compile(source, "<exception-table-test>", "exec").co_consts[0]


def _entry_values(entry) -> tuple[int, int, int, int, bool]:
    return entry.start, entry.end, entry.target, entry.depth, entry.lasti


class ExceptionTableParseTest(unittest.TestCase):
    def test_list_comprehension_matches_dis(self) -> None:
        code = _function_code("def f(): return [x for x in range(3)]")

        expected = list(dis._parse_exception_table(code))
        actual = exception_table.parse_exception_table(code)

        self.assertEqual(
            [_entry_values(entry) for entry in actual],
            [_entry_values(entry) for entry in expected],
        )
        self.assertEqual(
            [_entry_values(entry) for entry in actual],
            [(28, 48, 54, 2, False)],
        )

    def test_nested_try_matches_dis(self) -> None:
        code = _function_code(
            """\
def f():
    try:
        try:
            raise StopIteration
        except StopIteration:
            return 1
    except StopIteration:
        return 2
"""
        )

        expected = list(dis._parse_exception_table(code))
        actual = exception_table.parse_exception_table(code.co_exceptiontable)

        self.assertGreater(len(actual), 1)
        self.assertEqual(
            [_entry_values(entry) for entry in actual],
            [_entry_values(entry) for entry in expected],
        )

    def test_empty_table(self) -> None:
        code = _function_code("def f(): return 1")
        self.assertEqual(exception_table.parse_exception_table(code), [])

    def test_slot_conversion_uses_relative_ranges_and_absolute_target(self) -> None:
        code = _function_code("def f(): return [x for x in range(3)]")

        self.assertEqual(
            exception_table.parse_exception_table_slots(code, code_entry_slot=100),
            [
                exception_table.SlotExceptionTableEntry(
                    start_slot=14,
                    end_slot=24,
                    target_slot=127,
                    depth=2,
                    lasti=False,
                )
            ],
        )

    def test_slot_conversion_rejects_odd_offsets(self) -> None:
        entry = exception_table.ExceptionTableEntry(1, 2, 4, 0, False)
        with self.assertRaisesRegex(ValueError, "offsets must be even"):
            exception_table.entries_to_slots([entry], code_entry_slot=0)


if __name__ == "__main__":
    unittest.main()
