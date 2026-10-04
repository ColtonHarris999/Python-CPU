"""GC: containers of every kind survive collections intact (gc_plan.md Phase 0).

Lists, tuples, dicts (with a None key and a deleted entry), sets, and
runtime LONG_STR values are built, some are dropped, and the program collects
twice. The checksum depends only on the surviving data; the oracle checks
each collection's free set from the dumps. No container grows, so the program
runs on the single-core top.
"""


def build(n):
    lst = [n, n * 2, n * 3, n * 4]
    text = "container number " + str(n) + " with a long tail"
    tup = (1, text, [n, n + 1])
    d = {"k": lst, 7: tup, None: n, "gone": n}
    del d["gone"]
    s = {1, 2, 3, n}
    return [lst, tup, d, s]


def checksum(objs):
    lst, tup, d, s = objs
    total = lst[0] + lst[1] + lst[2] + lst[3] + len(tup[1]) + tup[2][0] + tup[2][1]
    total += len(d["k"]) + d[None] + len(s) + len(d)
    return total


def managed_entry():
    keep = build(10)
    garbage = build(20)
    garbage = None
    _bi_gc_collect()
    more = build(5)
    _bi_gc_collect()
    return checksum(keep) * 1000 + checksum(more)


managed_entry()
