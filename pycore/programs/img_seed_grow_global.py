"""SEED_INSTANCE STORE_ATTR grow then LOAD_GLOBAL — globals must survive.

# pycore-inject: SEED_INSTANCE o slots=4
"""

MARKER = 99


def managed_entry():
    o.a = 1
    o.b = 2
    o.c = 3
    o.d = 4
    return MARKER


managed_entry()
