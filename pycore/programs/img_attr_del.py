"""DELETE_ATTR then LOAD_ATTR → tombstone; second load traps ATTR_ERROR.

Trap test: expects PY_TRAP_ATTR_ERROR after delete.

# pycore-inject: SEED_INSTANCE o slots=4 x=5
"""


def managed_entry():
    del o.x
    return o.x


managed_entry()
