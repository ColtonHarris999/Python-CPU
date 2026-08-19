"""s[i] past the end must raise PY_TRAP_MEM_FAULT (trap 7), the same as lists.

CPython raises IndexError; PyCore has no exception object for it.
"""


def managed_entry():
    s = "abc"
    return s[5]


managed_entry()
