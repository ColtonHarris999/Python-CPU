"""GC gen Phase 0: STORE_DEREF of young objects into an old closure cell.

The image builder does not lower closures and the on-device compiler has no
`nonlocal`, so the closure comes from compile() and the stores are made by
the function that owns the cell. Its cell survives a collection (old), then
STORE_DEREF writes freshly allocated objects into it. Collections run between
the stores; the cell is read back through the inner function each time.
"""

SRC = """\
def run(collect, n):
    held = ["old-cell-content", 0]
    def get():
        return held
    collect()
    held = ["young-cell-content-" + str(n), (n, n * 2)]
    junk = ["junk", 1]
    junk = None
    collect()
    v = get()
    total = len(v[0]) + v[1][0] + v[1][1]
    held = ["second-young-content-" + str(n + 1), (n + 1, n)]
    collect()
    v = get()
    return total * 10 + len(v[0]) + v[1][0] + v[1][1]
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    run = ns["run"]
    ns = None
    return run(_bi_gc_collect, 7) * 100 + run(_bi_gc_collect, 9)


managed_entry()
