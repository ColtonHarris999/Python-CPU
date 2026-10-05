"""Dropping live data after MemoryError permits allocation to resume.

# pycore-expect: 1
"""


def managed_entry():
    chain = None
    try:
        i = 0
        while i < 100:
            chain = (chain, [i] * 128)
            i = i + 1
    except MemoryError:
        chain = None
        _bi_gc_collect()
        probe = (11, 22, 33)
        if len(probe) == 3:
            return 1
    return 0


managed_entry()
