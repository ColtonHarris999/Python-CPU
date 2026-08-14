"""Bound method + CALL_KW (no **kwargs): self must not steal kwargs slots.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T m = add
# pycore-inject: SEED_INSTANCE o type=T
"""


def add(self, a, b=0):
    return a + 10 * b


def managed_entry():
    # o.m(1, b=2) → 21; o.m(b=3, a=4) → 34
    return o.m(1, b=2) + o.m(b=3, a=4)


managed_entry()
