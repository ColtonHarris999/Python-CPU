"""GC gen Phase 3: STORE_DEREF into an old cell, with minors in between.

Like img_gen_store_deref, the closure comes from compile(). One explicit
collection makes the cell old; a loop then stores fresh objects into it and
churns, so `+GC_AT_BOUNDARY_EVERY` collections (minors) land between a store
and the read that follows it.
"""

SRC = """\
def run(collect, churn, n):
    held = ["old-cell-content", 0]
    def get():
        return held
    collect()
    total = 0
    for i in range(n):
        held = ["young-cell-content-" + str(i), (i, i * 2)]
        churn(10)
        v = get()
        total = total + len(v[0]) + v[1][0] + v[1][1]
    return total
"""


def churn(n):
    t = None
    for i in range(n):
        t = ("churn", i, [i, i])
    return t


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    run = ns["run"]
    ns = None
    return run(_bi_gc_collect, churn, 25)


managed_entry()
