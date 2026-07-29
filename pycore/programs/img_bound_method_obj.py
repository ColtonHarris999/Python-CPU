"""Non-method LOAD_ATTR of a TYPE-sourced CODE_OBJECT → OBK_BOUND_METHOD.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T m = add_one
# pycore-inject: SEED_INSTANCE o type=T
"""


def add_one(self, x):
    return x + 1


def managed_entry():
    f = o.m
    return f(1)


managed_entry()
