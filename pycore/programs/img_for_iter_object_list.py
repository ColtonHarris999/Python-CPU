"""GET_ITER object → __iter__ returns list → native FOR_ITER.

# pycore-expect: 6
# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __iter__ = iter_list
# pycore-inject: SEED_INSTANCE o type=T
"""


def iter_list(self):
    a = 1
    b = 2
    c = 3
    return [a, b, c]


def managed_entry():
    total = 0
    for x in o:
        total += x
    return total


managed_entry()
