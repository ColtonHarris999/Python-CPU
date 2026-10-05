"""GC: static containers pointing at fresh allocations keep them (gc_plan.md §6.4).

`o` is a seeded instance whose attribute dict lives in the static image, and
the module globals dict is static too. The entry stores freshly allocated
objects into both and collects; those objects are reachable only through
the static containers.
"""
# pycore-inject: SEED_INSTANCE o slots=4 x=0 y=0

G = None


def fill(n):
    global G
    G = [n, "module-global-owned-" + str(n)]
    o.x = ("seeded-instance-owned-" + str(n), n)
    o.y = {"inner": "seeded-dict-owned-" + str(n), "n": n}


def managed_entry():
    fill(5)
    _bi_gc_collect()
    junk = [len(G), 2, 3]
    junk = None
    _bi_gc_collect()
    total = G[0] + len(G[1]) + len(o.x[0]) + o.x[1] + len(o.y["inner"]) + o.y["n"]
    fill(9)
    _bi_gc_collect()
    return total * 1000 + G[0] + o.y["n"]


managed_entry()
