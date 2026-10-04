"""Release zeroing writes zeros even after a MemoryError that skipped runs.

Run with `+GC_AUTO=0` (no collection on an empty run list). An explicit
collection leaves small holes on the run list; a list too large for any of
them skips each one (writing its skipped-run header) and raises MemoryError
without collecting, so the current run survives. A mark / build / release in
that run must then zero with zero data: review round 3 found the release
pass reusing the allocator's last header word, which planted phantom keys.

# pycore-expect: 0
"""


def too_big():
    try:
        big = [0] * 40000
    except MemoryError:
        return 1
    return len(big) - 40000


def managed_entry():
    keep = [None] * 24
    hole = [None] * 24
    i = 0
    while i < 24:
        keep[i] = (i, i + 1)
        hole[i] = [i] * 80
        i = i + 1
    hole = None
    _bi_gc_collect()
    # Use up the small low holes so the next run is one of the large ones.
    filler = [keep] * 40
    too_big()
    # Leave the mark off a 64-byte line so the pass uses word writes.
    pad = (keep,)
    m = _bi_heap_mark()
    a = 0
    d1 = {a: 1, a + 1: 1, a + 2: 1}
    d1 = None
    _bi_heap_release(m)
    d2 = {}
    s2 = {a + 100}
    bad = 0
    i = 0
    while i < 3:
        if i in d2:
            bad = bad + 1
        if i in s2:
            bad = bad + 100
        i = i + 1
    return bad + len(d2) + len(s2) - 1 + len(keep) + len(pad) + len(filler) - 65


managed_entry()
