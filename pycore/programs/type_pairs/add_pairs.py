"""Simple Python add programs for PyCore type-pair tests."""

CASES = [
    {"name": "add_int_int", "lhs_tag": "INT", "rhs_tag": "INT", "expect_trap": False, "expected_tag": "INT", "expected": 4},
    {"name": "add_int_float", "lhs_tag": "INT", "rhs_tag": "FLOAT", "expect_trap": False, "expected_tag": "FLOAT", "expected": 3.5},
    {"name": "add_int_bool", "lhs_tag": "INT", "rhs_tag": "BOOL", "expect_trap": False, "expected_tag": "INT", "expected": 3},
    {"name": "add_int_object", "lhs_tag": "INT", "rhs_tag": "OBJECT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_float_int", "lhs_tag": "FLOAT", "rhs_tag": "INT", "expect_trap": False, "expected_tag": "FLOAT", "expected": 3.5},
    {"name": "add_float_float", "lhs_tag": "FLOAT", "rhs_tag": "FLOAT", "expect_trap": False, "expected_tag": "FLOAT", "expected": 3.0},
    {"name": "add_float_bool", "lhs_tag": "FLOAT", "rhs_tag": "BOOL", "expect_trap": False, "expected_tag": "FLOAT", "expected": 2.5},
    {"name": "add_float_object", "lhs_tag": "FLOAT", "rhs_tag": "OBJECT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_bool_int", "lhs_tag": "BOOL", "rhs_tag": "INT", "expect_trap": False, "expected_tag": "INT", "expected": 3},
    {"name": "add_bool_float", "lhs_tag": "BOOL", "rhs_tag": "FLOAT", "expect_trap": False, "expected_tag": "FLOAT", "expected": 2.5},
    {"name": "add_bool_bool", "lhs_tag": "BOOL", "rhs_tag": "BOOL", "expect_trap": False, "expected_tag": "INT", "expected": 2},
    {"name": "add_bool_object", "lhs_tag": "BOOL", "rhs_tag": "OBJECT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_object_int", "lhs_tag": "OBJECT", "rhs_tag": "INT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_object_float", "lhs_tag": "OBJECT", "rhs_tag": "FLOAT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_object_bool", "lhs_tag": "OBJECT", "rhs_tag": "BOOL", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
    {"name": "add_object_object", "lhs_tag": "OBJECT", "rhs_tag": "OBJECT", "expect_trap": True, "expected_tag": "OBJECT", "expected": None},
]


def add_int_int():
    lhs = 2
    rhs = 2
    return lhs + rhs


def add_int_float():
    lhs = 2
    rhs = 1.5
    return lhs + rhs


def add_int_bool():
    lhs = 2
    rhs = True
    return lhs + rhs


def add_int_object():
    lhs = 2
    rhs = None
    return lhs + rhs


def add_float_int():
    lhs = 1.5
    rhs = 2
    return lhs + rhs


def add_float_float():
    lhs = 1.5
    rhs = 1.5
    return lhs + rhs


def add_float_bool():
    lhs = 1.5
    rhs = True
    return lhs + rhs


def add_float_object():
    lhs = 1.5
    rhs = None
    return lhs + rhs


def add_bool_int():
    lhs = True
    rhs = 2
    return lhs + rhs


def add_bool_float():
    lhs = True
    rhs = 1.5
    return lhs + rhs


def add_bool_bool():
    lhs = True
    rhs = True
    return lhs + rhs


def add_bool_object():
    lhs = True
    rhs = None
    return lhs + rhs


def add_object_int():
    lhs = None
    rhs = 2
    return lhs + rhs


def add_object_float():
    lhs = None
    rhs = 1.5
    return lhs + rhs


def add_object_bool():
    lhs = None
    rhs = True
    return lhs + rhs


def add_object_object():
    lhs = None
    rhs = None
    return lhs + rhs
