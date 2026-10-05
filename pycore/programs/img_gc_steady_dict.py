"""GC steady state, dicts (gc_plan.md G11): 1,000 build/update/delete/drop iterations.

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
        d = {"a": i, "b": "steady-dict-value-" + str(i % 9), None: [i], 7: (i, i)}
        d["a"] = d["a"] + 1
        del d[7]
        d[7] = i % 4
        total = total + d["a"] % 5 + len(d["b"]) + d[None][0] % 3 + d[7] + len(d)
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
