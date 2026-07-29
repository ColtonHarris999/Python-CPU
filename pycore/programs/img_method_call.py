"""Bound-method form: o.m(1) → LOAD_ATTR|1 + CALL 1 (no BM allocation).

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T m = add_one
# pycore-inject: SEED_INSTANCE o type=T
"""


def add_one(self, x):
    return x + 1


def managed_entry():
    return o.m(1)


managed_entry()
