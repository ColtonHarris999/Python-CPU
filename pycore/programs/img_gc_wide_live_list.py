"""GC: a wide live list must not make collection fail on a mostly empty heap.

18,000 live 1-tuples in one list is about 1.2 MB of a 15 MB heap. When
marking pushed every element of the list, the mark stack (16,640 entries)
overflowed and the collection raised MemoryError with almost all of the heap
free. The list buffer is now scanned in 64-slot chunks, so the stack holds
one chunk and a continuation.

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
