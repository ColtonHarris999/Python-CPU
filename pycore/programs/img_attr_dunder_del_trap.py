"""DELETE_ATTR on __class__ → PY_TRAP_TYPE (1).

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_INSTANCE o type=T slots=4
"""


def managed_entry():
    del o.__class__
    return 0


managed_entry()
