"""GC steady state, closures (gc_plan.md G11): 1,000 closures with cells, called and dropped.

The factory comes from the on-device compiler (closures are not in the image
path); each iteration creates a cell and a FUNCTION object.

Self-checking: after WARMUP iterations the program measures live bytes with
`_bi_gc_collect()` (precise, so the exact reachable set), runs the rest, and
measures again. Any growth returns minus the growth in bytes; otherwise the
checksum, which host CPython (where `_bi_gc_collect()` returns 0) gives as the
golden. G11 also checks the plateau at every collection (+GC_LOG=1).
"""

SRC = """\
def make(k):
    def add(x):
        return x + k
    return add
"""

WARMUP = 80
ITERS = 1000


def work(make, lo, hi):
    total = 0
    for i in range(lo, hi):
        f = make(i % 10)
        total = total + f(i) % 13
        if i % 80 == 0:
            _bi_gc_collect()
    return total


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    make = ns["make"]
    ns = None
    total = work(make, 0, WARMUP)
    base = _bi_gc_collect()
    total = total + work(make, WARMUP, ITERS)
    after = _bi_gc_collect()
    if after > base:
        return base - after
    return total


managed_entry()
