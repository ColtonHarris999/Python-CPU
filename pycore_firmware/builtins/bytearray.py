"""Mutable bytearray.

Seeded as BI_BYTEARRAY; CALL traps to excore (PY_TRAP_BUILTIN_CALL).
Pure-Python body cannot allocate MUT_BYTEARRAY.
"""


def bytearray(source=None):
    return 1 % 0
