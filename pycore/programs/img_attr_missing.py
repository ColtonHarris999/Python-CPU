"""LOAD_ATTR on an absent name → PY_TRAP_ATTR_ERROR (15).

# pycore-inject: SEED_INSTANCE o slots=4
"""


def managed_entry():
    return o.missing


managed_entry()
