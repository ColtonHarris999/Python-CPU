"""GC steady state, lists (gc_plan.md G11): 1,000 build-and-drop iterations.

Each iteration's working set is a few hundred bytes; the test shrinks the
heap (HEAP_DYN_BYTES) so the run collects many times.

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
    keep = [total, total, total]
    for i in range(lo, hi):
        a = [i, i + 1, "steady-list-element-" + str(i % 7)]
        b = [a, [i], a[2]]
        c = b + [i % 5]
        keep[i % 3] = c[3]
        total = total + len(c) + len(a[2]) + b[1][0] % 3
    return total + keep[0] + keep[1] + keep[2]


def managed_entry():
    total = work(0, WARMUP)
    base = _bi_gc_collect()
    total = total + work(WARMUP, ITERS)
    after = _bi_gc_collect()
    if after > base:
        return base - after
    return total


managed_entry()
