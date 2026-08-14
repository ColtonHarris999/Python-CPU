"""Bound method with **kwargs (self + leftover packing).

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T m = add_kw
# pycore-inject: SEED_INSTANCE o type=T
"""


def add_kw(self, a=0, **k):
    return a + 10 * len(k) + (0 if len(k) == 0 else k["x"])


def managed_entry():
    # o.m(1, x=2) → 1 + 10 + 2 = 13; o.m() → 0
    return o.m(1, x=2) + o.m()


managed_entry()
