"""GC: more free runs than the run table holds is not an out-of-memory.

Each iteration keeps one 32 B tuple and drops a 96 B tuple behind it, so the
sweep finds one free run of at least 64 B per kept tuple: about 16,000 runs,
more than the 1,024 on-chip entries plus the 13,248-slot overflow table
(14,272). The sweep used to abort there: the collection raised MemoryError
with most of the heap free and left the rest of the mark bitmap set. Now the
runs past the table stay unlisted until a later collection, both collections
succeed, and the kept tuples keep their values after the heap is reused.

# pycore-expect: 1
"""


def collect():
    try:
        _bi_gc_collect()
    except MemoryError:
        return 1
    return 0


def managed_entry():
    n = 16000
    keep = [None] * n
    i = 0
    while i < n:
        keep[i] = (i,)
        drop = (i, i, i)
        i = i + 1
    drop = None
    if collect() != 0:
        return 2
    junk = [None] * n
    i = 0
    while i < n:
        junk[i] = (i, i, 7)
        i = i + 1
    if collect() != 0:
        return 3
    junk = [None] * n
    i = 0
    while i < n:
        junk[i] = [i, 9]
        i = i + 1
    i = 0
    while i < n:
        if keep[i][0] != i:
            return 100 + i
        i = i + 1
    return 1


managed_entry()
