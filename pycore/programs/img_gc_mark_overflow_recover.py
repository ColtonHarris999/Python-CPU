"""GC: a collection that aborts on mark-stack overflow must not corrupt the next one.

Wide containers are scanned in 64-slot chunks, so only nesting fills the
mark stack (256 on chip plus 16,384 in memory). `deep` is 300 nested
70-element lists; each holds the next one at slot 63, the last child of its
first chunk, so marking keeps about 65 entries per level pending and the
explicit collection overflows and raises MemoryError. The program cuts the
chain to its outer 75 levels (below the stack bound) and collects again.
Every eighth element is a 1-tuple whose child is a list. The aborted
collection marked each tuple when it pushed it but never scanned it, so if
the abort leaves the mark bitmap dirty, the second collection treats the
tuples as already marked and frees their lists while `deep` still reaches
them. Reusing that memory then changes what `row[j][0][0]` reads.

# pycore-expect: 1
"""


def collect():
    try:
        _bi_gc_collect()
    except MemoryError:
        return 1
    return 0


def managed_entry():
    levels = 300
    width = 70
    deep = None
    lv = 0
    while lv < levels:
        row = [None] * width
        j = 0
        while j < width:
            i = lv * width + j
            if j == 63:
                row[j] = deep
            elif i % 8 == 0:
                row[j] = ([i, 0, 0, 0],)
            else:
                row[j] = (i,)
            j = j + 1
        deep = row
        lv = lv + 1
    if collect() != 1:
        return 3
    # Keep the outer quarter of the chain and collect again.
    keep = levels // 4
    row = deep
    k = 1
    while k < keep:
        row = row[63]
        k = k + 1
    row[63] = None
    if collect() != 0:
        return 4
    junk = [None] * (keep * width)
    i = 0
    while i < keep * width:
        junk[i] = [1000000 + i, 0, 0, 0]
        i = i + 1
    row = deep
    lv = levels - 1
    while row is not None:
        j = 0
        while j < width:
            i = lv * width + j
            if j != 63 and i % 8 == 0 and row[j][0][0] != i:
                return 100 + i
            j = j + 1
        row = row[63]
        lv = lv - 1
    return 1


managed_entry()
