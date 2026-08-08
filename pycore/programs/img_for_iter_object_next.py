"""HEAP_ITER: __iter__ returns self; __next__ yields then StopIteration.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __iter__ = iter_self
# pycore-inject: SEED_TYPE_METHOD T __next__ = next_t
# pycore-inject: SEED_INSTANCE o type=T slots=4
"""


def iter_self(self):
    self.i = 0
    return self


def next_t(self):
    i = self.i
    if i >= 3:
        raise StopIteration
    self.i = i + 1
    return i + 1


def managed_entry():
    total = 0
    for x in o:
        total += x
    return total


managed_entry()
