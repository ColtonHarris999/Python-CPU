"""Bound method with positional default; o.m() supplies only self.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T m = add_n
# pycore-inject: SEED_INSTANCE o type=T
"""


def add_n(self, n=5):
    return n + 1


def managed_entry():
    return o.m() + o.m(2)


managed_entry()
