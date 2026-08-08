"""Nested object for-loops (list-returning __iter__).

# pycore-expect: 9
# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __iter__ = iter_list
# pycore-inject: SEED_INSTANCE o type=T
# pycore-inject: SEED_INSTANCE p type=T
"""


def iter_list(self):
    a = 1
    b = 2
    return [a, b]


def managed_entry():
    total = 0
    for x in o:
        for y in p:
            total += x * y
    return total


managed_entry()
