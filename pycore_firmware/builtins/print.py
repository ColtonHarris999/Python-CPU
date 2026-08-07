"""Print objects to a stream.

I/O is an excore concern (BI_PRINT → PY_TRAP_BUILTIN_CALL). Full plan:
``planning/builtins_print_console_plan.md``. A CODE_OBJECT wrapper may
use ``sep=`` / ``end=`` via CALL_KW in Phase 2 once the console sink
exists.
"""


def print(a=None, b=None, c=None, d=None):
    return 1 % 0
