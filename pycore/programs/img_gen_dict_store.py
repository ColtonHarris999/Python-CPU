"""GC gen Phase 0: `old[k] = fresh` on an old dict, new keys and overwrites.

The dict survives a collection, then gets young values under existing keys
(overwrite) and under enough new young string keys to grow the table. A second
collection runs before everything is read back.
"""


def fresh(n):
    return ["young-dict-value-" + str(n), n * 7]


def managed_entry():
    old = {}
    for i in range(4):
        old["k" + str(i)] = ("old-value", i)
    _bi_gc_collect()
    for i in range(4):
        old["k" + str(i)] = fresh(i)
    for i in range(4, 40):
        old["new-young-key-" + str(i)] = fresh(i)
    old["k1"] = fresh(101)
    t = fresh(555)
    t = None
    _bi_gc_collect()
    total = len(old)
    for i in range(4):
        v = old["k" + str(i)]
        total = total + len(v[0]) + v[1]
    for i in range(4, 40):
        v = old["new-young-key-" + str(i)]
        total = total + len(v[0]) * 2 + v[1]
    for k in old:
        total = total + len(k)
    return total


managed_entry()
