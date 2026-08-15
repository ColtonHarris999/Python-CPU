"""Empty object iterator exhausts without body execution.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __iter__ = iter_self
# pycore-inject: SEED_TYPE_METHOD T __next__ = next_empty
# pycore-inject: SEED_INSTANCE o type=T
"""


def iter_self(self):
    return self


def next_empty(self):
    raise StopIteration


def managed_entry():
    total = 7
    for x in o:
        total += 100
    return total


managed_entry()
