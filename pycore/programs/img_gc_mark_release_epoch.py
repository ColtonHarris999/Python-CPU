"""GC: heap marks carry the collection epoch (gc_plan.md §5.4).

A release to a mark taken in the same epoch rewinds the cursor exactly as
without a collector. A mark taken before a collection is superseded: the
release is a no-op and `_bi_gc_stats(5)` counts it. The stale-mark and
below-base traps keep their goldens (img_heap_release_*_trap).

Marks and counters only exist on PyCore, so the expected value is stated.
# pycore-expect: 1111
"""


def managed_entry():
    total = 0
    m = _bi_heap_mark()
    a = [m, m + 1, m + 2]
    a = None
    _bi_heap_release(m)
    m_after = _bi_heap_mark()
    # Same-epoch rewind, or an intervening collection (§5.4 no-op).
    if (m_after >> 32) != (m >> 32) or m_after == m:
        total += 1
    old = _bi_heap_mark()
    b = [old, old + 1]
    b = None
    _bi_gc_collect()
    before = _bi_gc_stats(5)
    _bi_heap_release(old)
    if _bi_gc_stats(5) == before + 1:
        total += 10
    if _bi_heap_mark() != old:
        total += 100
    m2 = _bi_heap_mark()
    c = (1, 2)
    c = None
    _bi_heap_release(m2)
    m2_after = _bi_heap_mark()
    if (m2_after >> 32) != (m2 >> 32) or m2_after == m2:
        total += 1000
    return total


managed_entry()
