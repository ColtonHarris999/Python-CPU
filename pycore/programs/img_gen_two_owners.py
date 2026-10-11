"""GC gen Phase 0: one statement sequence mutates two old owners.

An old dict holds an old list. After a collection, `d[k].append(fresh)` writes
a young object into the old list and `d[k2] = fresh2` writes another into the
old dict, back to back. A second collection runs before both are read back.
"""


def fresh(n):
    return ["two-owner-young-" + str(n), n]


def managed_entry():
    d = {"lst": ["old-element"], "other": "old-value"}
    _bi_gc_collect()
    for i in range(10):
        d["lst"].append(fresh(i))
        d["k" + str(i)] = fresh(i + 100)
    d["lst"][0] = fresh(77)
    d["other"] = d["lst"]
    _bi_gc_collect()
    total = len(d) + len(d["lst"])
    for v in d["lst"]:
        total = total + len(v[0]) + v[1]
    for i in range(10):
        v = d["k" + str(i)]
        total = total + len(v[0]) + v[1]
    if d["other"] is d["lst"]:
        total = total + 1000
    return total


managed_entry()
