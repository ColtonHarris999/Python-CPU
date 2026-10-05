"""A final GC allocation failure raises a catchable MemoryError.

# pycore-expect: 1
"""


def managed_entry():
    _bi_gc_collect()
    try:
        values = [3] * 10000
    except MemoryError:
        return 1
    return 0


managed_entry()
