"""Nested bound calls: self._a(self._b(x)).

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T _a = meth_a
# pycore-inject: SEED_TYPE_METHOD T _b = meth_b
# pycore-inject: SEED_INSTANCE o type=T
"""


def meth_b(self, x):
    return x + 1


def meth_a(self, x):
    return x * 2


def managed_entry():
    return o._a(o._b(3))


managed_entry()
