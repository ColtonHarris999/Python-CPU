"""BI_LEN on INSTANCE without __len__ → PY_TRAP_ATTR_ERROR (15).

# pycore-inject: SEED_TYPE Empty
"""


def managed_entry():
    e = Empty()
    return len(e)


managed_entry()
