"""GC: a collection that aborts on rescan-list overflow must not corrupt the next one.

The test runs with a 64-entry mark stack and a 64-entry rescan list
(hw_tests.toml plusargs). Each 128-slot chunk of `wide` overflows the stack
and is recorded for a rescan while the continuation of the list stays on
the stack, so its 141 chunks fill the rescan list: the explicit collection
is abandoned and raises MemoryError. The program catches it, drops most of
`wide` (36 chunks remain, which fit) and collects again. Every eighth
element is a 1-tuple whose child is a list. The aborted collection marked
each tuple when it pushed it but never scanned it, so if the abort leaves
the mark bitmap dirty, the second collection treats the tuples as already
marked and frees their lists while `keep` still reaches them. Reusing that
memory then changes what `keep[i][0][0]` reads.

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
    # Keep a quarter of the graph (its chunks fit the rescan list) and collect again.
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
