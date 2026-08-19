"""chr() above U+10FFFF must raise PY_TRAP_TYPE (trap 1).

CPython raises ValueError; PyCore has no exception object for it.
"""


def managed_entry():
    return chr(1114112)


managed_entry()
