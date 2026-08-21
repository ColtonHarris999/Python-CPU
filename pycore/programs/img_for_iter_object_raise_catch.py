"""A non-StopIteration protocol exception unwinds to the bytecode handler.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __iter__ = iter_self
# pycore-inject: SEED_TYPE_METHOD T __next__ = next_t
# pycore-inject: SEED_INSTANCE o type=T slots=4
"""


def iter_self(self):
    return self


def next_t(self):
    raise ValueError


def managed_entry():
    try:
        for x in o:
            return x
    except ValueError:
        return 1
    return 0


managed_entry()
