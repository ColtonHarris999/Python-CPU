"""ord() of a multi-character string must raise PY_TRAP_TYPE (trap 1).

CPython raises TypeError; PyCore has no exception object for it.
"""


def managed_entry():
    return ord("ab")


managed_entry()
