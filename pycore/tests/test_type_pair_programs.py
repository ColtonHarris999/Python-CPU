"""Unit tests for the Python source fixtures behind PyCore type-pair coverage."""

from __future__ import annotations

import importlib
import unittest


FIXTURE_MODULES = (
    "pycore.programs.type_pairs.add_pairs",
    "pycore.programs.type_pairs.mul_pairs",
)


class TypePairFixtureShapeTest(unittest.TestCase):
    def test_fixture_names_are_unique(self) -> None:
        names: set[str] = set()
        for module_name in FIXTURE_MODULES:
            module = importlib.import_module(module_name)
            for case in module.CASES:
                self.assertNotIn(case["name"], names)
                names.add(case["name"])

        self.assertEqual(len(names), 32)


def _make_case(module_name: str, case: dict[str, object]):
    def test(self: unittest.TestCase) -> None:
        module = importlib.import_module(module_name)
        fn = getattr(module, str(case["name"]))

        if case["expect_trap"]:
            with self.assertRaises(TypeError):
                fn()
        else:
            self.assertEqual(fn(), case["expected"])

        self.assertIn(case["lhs_tag"], {"INT", "FLOAT", "BOOL", "OBJECT"})
        self.assertIn(case["rhs_tag"], {"INT", "FLOAT", "BOOL", "OBJECT"})
        self.assertIn(case["expected_tag"], {"INT", "FLOAT", "BOOL", "OBJECT"})

    return test


for _module_name in FIXTURE_MODULES:
    _module = importlib.import_module(_module_name)
    for _case in _module.CASES:
        setattr(
            TypePairFixtureShapeTest,
            f"test_{_case['name']}",
            _make_case(_module_name, _case),
        )


if __name__ == "__main__":
    unittest.main()
