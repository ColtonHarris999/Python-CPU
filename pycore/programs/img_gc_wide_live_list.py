"""GC: a wide live list must not make collection fail on a mostly empty heap.

18,000 live 1-tuples in one list is about 1.2 MB of a 15 MB heap. Marking
used to push every element of the list when it scanned it, so the mark
stack (16,640 entries then) overflowed and the collection raised
MemoryError even though almost all of the heap was free. The marker now
scans a wide range in chunks and pushes the rest as one continuation entry.

# pycore-expect: 1
"""


def managed_entry():
    n = 18000
    wide = [None] * n
    i = 0
    while i < n:
        wide[i] = (i,)
        i = i + 1
    try:
        _bi_gc_collect()
    except MemoryError:
        return 2
    return 1


managed_entry()
