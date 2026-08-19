"""exec() of a non-code object must trap.

The ROM body calls its argument; CALL on an INT is not a valid callable, so
hardware raises PY_TRAP_CALL_FILTER (6). CPython raises TypeError.
"""


def managed_entry():
    return exec(5)


managed_entry()
