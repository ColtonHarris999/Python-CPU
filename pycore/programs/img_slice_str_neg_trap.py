"""Negative slice bounds wrap like CPython: "abcde"[1:-1] == "bcd".

STRACC uses signed character indices. The old string_mem path trapped
PY_TRAP_TYPE on negatives (bytecode_support.md deviation 3); the accelerator
matches CPython instead.
"""


def managed_entry():
    s = "abcde"
    one = 1
    neg = -1
    return len(s[one:neg])


managed_entry()
