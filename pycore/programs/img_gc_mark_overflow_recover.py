"""GC: a collection that aborts on mark-stack overflow must not corrupt the next one.

`wide` holds more pushable objects than the mark stack (256 on chip plus
16,384 in memory), so the explicit collection overflows and raises
MemoryError. The program catches it, drops most of `wide` and collects
again. Every eighth element is a 1-tuple whose child is a list. The aborted
collection marked each tuple when it pushed it but never scanned it, so if
the abort leaves the mark bitmap dirty, the second collection treats the
tuples as already marked and frees their lists while `keep` still reaches
them. Reusing that memory then changes what `keep[i][0][0]` reads.

# pycore-expect: 1
"""


def collect():
    try:
        _bi_gc_collect()
    except MemoryError:
        return 1
    return 0


def managed_entry():
    n = 18000
    wide = [None] * n
    i = 0
    while i < n:
        if i % 8 == 0:
            wide[i] = ([i, 0, 0, 0],)
        else:
            wide[i] = (i,)
        i = i + 1
    collect()
    # Keep a quarter of the graph (below the stack bound) and collect again.
    m = n // 4
    keep = [None] * m
    i = 0
    while i < m:
        keep[i] = wide[i]
        i = i + 1
    wide = None
    collect()
    junk = [None] * m
    i = 0
    while i < m:
        junk[i] = [1000000 + i, 0, 0, 0]
        i = i + 1
    i = 0
    while i < m:
        if i % 8 == 0 and keep[i][0][0] != i:
            return 100 + i
        i = i + 1
    return 1


managed_entry()
