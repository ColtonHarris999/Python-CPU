"""GC: overwritten bindings and popped stack slots are reclaimed (gc_plan.md §6.4
overwrite_locals_globals, stale_rf_pop).

Locals and a module global are rebound, so their old objects become garbage;
temporaries computed and discarded leave stale entries above `tos` in the RF
ring, which are not roots. The oracle checks precision at each collection.
"""

G = ["module-global-first-binding", 1]


def temps(n):
    len(["temporary-list-popped-" + str(n), n])
    (n, "temporary-tuple-popped")
    return n


def managed_entry():
    global G
    x = ["local-first-binding-long-enough", 1]
    x = ["local-second-binding-long-enough", 2]
    G = ["module-global-second-binding", 2]
    t = temps(3) + temps(4)
    _bi_gc_collect()
    y = [x, G, "after-collection"]
    _bi_gc_collect()
    return len(x[0]) + x[1] + len(G[0]) + G[1] + t + len(y)


managed_entry()
