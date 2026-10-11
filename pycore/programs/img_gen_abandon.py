"""GC gen Phase 2: an abandoned collection forces the next one to be a major.

The test runs with a 32-entry mark stack and an 8-entry rescan list
(hw_tests.toml plusargs). The explicit collection over `wide` overflows the
rescan list, is abandoned and raises MemoryError, which the program
catches. The abandoned marking left marks in the bitmap. `wide` is then
dropped and allocation churn fills the small heap (`+HEAP_DYN_BYTES`), so
an allocation collection follows with no explicit request: with
`+GC_GEN=1` it must be a major that clears those marks
(gc_gen_protocol.md N4); a minor would keep the stale marks as old objects.

# pycore-expect: 2
"""


def collect():
    try:
        _bi_gc_collect()
    except MemoryError:
        return 1
    return 0


def managed_entry():
    n = 2400
    wide = [None] * n
    i = 0
    while i < n:
        wide[i] = (i,)
        i = i + 1
    got = collect()
    wide = None
    total = 0
    i = 0
    while i < 3000:
        x = [i, i + 1, i + 2, i + 3]
        total = total + x[1] - i
        i = i + 1
    if total == 3000:
        got = got + 1
    return got


managed_entry()
