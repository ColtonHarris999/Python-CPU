"""LOAD_GLOBAL with namei >= 1 (oparg >> 1, null_bit clear).

Regression for the bug that gated the >>1 shift on the null bit, so
LOAD_GLOBAL of any name after the first in co_names raised MEM_FAULT.
"""

ALPHA = 1
BETA = 2
GAMMA = 3


def managed_entry():
    return ALPHA + BETA + GAMMA


managed_entry()
