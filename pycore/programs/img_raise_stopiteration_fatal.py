"""Unhandled ``raise StopIteration`` → fatal PY_TRAP_RAISE (17).

Empty ``co_exceptiontable`` (no try/except) must miss in get_exception_handler
and halt with trap 17 after building an OBK_EXCEPTION (§7.5 / §10 step 4).
"""


def managed_entry():
    raise StopIteration


managed_entry()
