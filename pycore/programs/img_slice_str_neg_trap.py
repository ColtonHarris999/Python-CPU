"""Negative slice bounds do not wrap: PY_TRAP_TYPE (1).

CPython gives "abcde"[1:-1] == "bcd". PyCore bounds are unsigned (the same
deviation 3 that applies to indices), so this traps rather than silently
computing something else. Documented in bytecode_support.md.
"""


def managed_entry():
    s = "abcde"
    one = 1
    neg = -1
    return len(s[one:neg])


managed_entry()
