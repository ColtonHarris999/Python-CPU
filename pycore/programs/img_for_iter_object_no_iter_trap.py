"""Object without __iter__ → PY_TRAP_TYPE on GET_ITER.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_INSTANCE o type=T
"""


def managed_entry():
    total = 0
    for x in o:
        total += x
    return total


managed_entry()
