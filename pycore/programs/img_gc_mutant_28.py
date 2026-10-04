"""Mutant 28: a free run too small for the request must go on the skipped
list, not vanish from `_bi_heap_free()`.

After an explicit collection the allocator walks the run list from its
head. The first runs are small holes left between kept tuples, so a request
larger than any hole skips each of them. Skipping keeps their bytes free:
`_bi_heap_free()` may drop by the request, not by the holes it passed.
Host `_bi_heap_free` is 0, so the check holds on CPython.

# pycore-expect: 1
"""


def managed_entry():
    keep = [None] * 40
    hole = [None] * 40
    i = 0
    while i < 40:
        keep[i] = (i, i + 1)
        hole[i] = (i, i, i, i, i, i, i, i)
        i = i + 1
    hole = None
    _bi_gc_collect()
    before = _bi_heap_free()
    big = [i] * 64
    after = _bi_heap_free()
    if before - after <= 4096:
        return len(big) - 63
    return 0


managed_entry()
