"""LEGB-B: LOAD_GLOBAL resolves a name present only in the builtins dict.

`len` is seeded in the boot-record builtins dict, not in module globals.
"""


def managed_entry():
    return len((1, 2, 3, 4))


managed_entry()
