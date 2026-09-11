"""Slicing a non-sequence (INT) still PY_TRAP_TYPE (1).

LIST/TUPLE slicing now executes; other subjects stay on CONT_SLICE_STR
which type-traps. The list was previously this fixture's subject.
"""


def managed_entry():
    zero = 0
    two = 2
    xs = 7
    return xs[zero:two]


managed_entry()
