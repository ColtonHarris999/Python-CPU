"""STORE_ATTR on __dict__ → PY_TRAP_TYPE (1).

# pycore-inject: SEED_INSTANCE o slots=4
"""


def managed_entry():
    o.__dict__ = 1
    return 0


managed_entry()
