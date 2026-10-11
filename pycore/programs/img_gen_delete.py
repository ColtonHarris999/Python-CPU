"""GC gen Phase 0: deletes from an old list and dict, then more young stores.

An old list and dict survive a collection, get young objects, lose some
entries by `del old[i]`, `old.pop()` and `del d[k]`, then receive more young
objects. A second collection runs before what remains is read back.
"""


def fresh(n):
    return ["young-after-delete-" + str(n), n]


def managed_entry():
    old = [("old", i) for i in range(6)]
    d = {"x": ("old", 1), "y": ("old", 2)}
    _bi_gc_collect()
    for i in range(6):
        old.append(fresh(i))
        d["f" + str(i)] = fresh(i + 10)
    del old[2]
    del old[0]
    popped = old.pop()
    del d["x"]
    del d["f3"]
    old.append(fresh(20))
    old[1] = fresh(21)
    d["f3"] = fresh(22)
    d["z"] = fresh(23)
    _bi_gc_collect()
    total = len(old) * 100 + len(d) + popped[1]
    for v in old:
        total = total + len(v[0]) + v[1]
    for k in d:
        v = d[k]
        total = total + len(k) + len(v[0]) + v[1]
    return total


managed_entry()
