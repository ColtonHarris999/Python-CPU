"""Print objects to a stream.

I/O is an excore concern (BI_PRINT → PY_TRAP_BUILTIN_CALL). Pure Python
cannot write to a host stdout from the hart. sep/end/file kwargs need
CALL_KW (deferred) even after I/O exists.
"""


def print(a=None, b=None, c=None, d=None):
    return 1 % 0
