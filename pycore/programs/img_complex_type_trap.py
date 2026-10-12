"""complex() with a complex component is PY_TRAP_TYPE (trap 1).

CPython raises TypeError for complex(1, 1j). No string form here.
"""


def managed_entry():
    return complex(1, 1j)


managed_entry()
