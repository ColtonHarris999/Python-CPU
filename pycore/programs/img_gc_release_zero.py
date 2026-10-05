"""`_bi_heap_release` hands back zeroed bytes (gc.md invariant 6).

A dict and a set are built after a mark and dropped, the cursor is released
to the mark, and an empty dict and set are built in the same bytes. Their
tables must be empty: stale keys from the released tables would make the
membership tests hit. Review round 2: the release only rewound the cursor,
and keep-run (G13 P8) no longer re-zeroed the run at a boundary collection.

# pycore-expect: 0
"""


def managed_entry():
    m = _bi_heap_mark()
    a = 0
    d1 = {a: 1, a + 1: 1, a + 2: 1, a + 3: 1, a + 4: 1, a + 5: 1, a + 6: 1,
          a + 7: 1, a + 8: 1, a + 9: 1, a + 10: 1, a + 11: 1}
    s1 = {a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, a + 8, a + 9}
    d1 = None
    s1 = None
    _bi_heap_release(m)
    d2 = {}
    s2 = {a + 100}
    bad = 0
    i = 0
    while i < 12:
        if i in d2:
            bad = bad + 1
        if i in s2:
            bad = bad + 100
        i = i + 1
    return bad + len(d2) + len(s2) - 1


managed_entry()
