"""GC steady state, strings (gc_plan.md G11): concat, join, split, replace, drop.

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
        s = "steady-string-number-" + str(i) + "-with-tail"
        j = "|".join([s, "middle-part-of-join", str(i % 7)])
        parts = j.split("|")
        r = parts[0].replace("-", "+")
        total = total + len(parts) + len(r) + len(parts[1]) + len(j) % 11
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
