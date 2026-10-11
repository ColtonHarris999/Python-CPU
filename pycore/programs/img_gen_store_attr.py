"""GC gen Phase 0: STORE_ATTR of young objects on an old instance.

An instance survives a collection, then has existing attributes overwritten
and new attributes added with freshly allocated values. A second collection
runs before every attribute is read back.
"""


class Holder:
    def __init__(self):
        self.a = "old-attribute-a"
        self.b = 1


def fresh(n):
    return ["young-attribute-value-" + str(n), (n, n + 1)]


def managed_entry():
    h = Holder()
    _bi_gc_collect()
    h.a = fresh(1)
    h.b = fresh(2)
    h.c = fresh(3)
    h.d = {"inner": fresh(4)}
    h.e = Holder()
    h.e.a = fresh(5)
    junk = fresh(6)
    junk = None
    _bi_gc_collect()
    total = len(h.a[0]) + h.a[1][1]
    total = total * 3 + len(h.b[0]) + h.b[1][0]
    total = total * 3 + len(h.c[0]) + h.c[1][1]
    total = total * 3 + len(h.d["inner"][0]) + h.d["inner"][1][0]
    total = total * 3 + len(h.e.a[0]) + h.e.b
    return total


managed_entry()
