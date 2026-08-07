"""Unsupported tag to _bi_print / print → TYPE trap.

Passing a list forces native BI_PRINT TYPE fatal (LONG_STR deferred;
containers unsupported).
"""


def managed_entry():
    print([1])
    return 0


managed_entry()
