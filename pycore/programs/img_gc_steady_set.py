"""GC steady state, sets (gc_plan.md G11): 1,000 build-and-drop iterations.

Self-checking: after WARMUP iterations the program measures live bytes with
`_bi_gc_collect()` (precise, so the exact reachable set), runs the rest, and
measures again. Any growth returns minus the growth in bytes; otherwise the
checksum, which host CPython (where `_bi_gc_collect()` returns 0) gives as the
golden. G11 also checks the plateau at every collection (+GC_LOG=1).
"""

WARMUP = 100
ITERS = 1000


def work(lo, hi):
    total = 0
    for i in range(lo, hi):
        s = {i % 11, i % 13, i % 17, i + 1000}
        t = set((i % 3, i % 5, 99))
        s.add(i % 11)
        if (i % 13) in s:
            total = total + 1
        total = total + len(s) + len(t)
    return total


def managed_entry():
    total = work(0, WARMUP)
    base = _bi_gc_collect()
    total = total + work(WARMUP, ITERS)
    after = _bi_gc_collect()
    if after > base:
        return base - after
    return total


managed_entry()
