"""Print objects to a stream.

I/O is an excore concern (BI_PRINT → PY_TRAP_BUILTIN_CALL). Needs a
console MMIO + excore handler before ROM seeding (see
``planning/builtins_wave4_plan.md`` §1). A CODE_OBJECT wrapper may use
``sep=`` / ``end=`` via CALL_KW once I/O exists.
"""


def print(a=None, b=None, c=None, d=None):
    return 1 % 0
