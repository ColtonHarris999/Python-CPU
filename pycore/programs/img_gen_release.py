"""GC gen Phase 2: a heap release forces the next collection to be a major.

An old list survives an explicit (major) collection. A mark is taken, a
batch of strings is allocated and dropped, and the cursor is released to
the mark. Allocation churn then fills the small heap
(`+HEAP_DYN_BYTES`), so an allocation collection follows the release with
no explicit request: with `+GC_GEN=1` it must be a major
(gc_gen_protocol.md R1). The old list must read back unchanged.

# pycore-expect: 45560
"""


def managed_entry():
    old = []
    for i in range(20):
        old.append("old-" + str(i))
    _bi_gc_collect()
    # An explicit collection leaves no current run: install one before the
    # mark, so the release rewinds within it.
    warm = [0, 1]
    m = _bi_heap_mark()
    tmp = []
    for i in range(12):
        tmp.append("released-" + str(i * 7))
    tmp = None
    _bi_heap_release(m)
    total = 0
    for i in range(300):
        x = [i, i + 1, i + 2, "churn-" + str(i)]
        total = total + x[2]
    for s in old:
        total = total + len(s)
    total = total + warm[1] - 1
    return total


managed_entry()
