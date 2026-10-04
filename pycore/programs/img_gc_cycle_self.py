"""GC: an unreachable self-referencing list is reclaimed (gc_plan.md §6.4).

A list that contains itself and a dict whose value is the dict are dropped;
the oracle checks at each collection that their extents are free. The
surviving cycle is walked for the checksum.
"""


def make_cycle(n):
    a = [n, "self-cycle-payload-" + str(n), None]
    a[2] = a
    d = {"me": None, "n": n}
    d["me"] = d
    return [a, d]


def managed_entry():
    keep = make_cycle(1)
    junk = make_cycle(2)
    junk = make_cycle(3)
    junk = None
    _bi_gc_collect()
    again = make_cycle(4)
    _bi_gc_collect()
    a, d = keep
    total = a[0] + len(a[1]) + a[2][2][0] + d["me"]["me"]["n"]
    return total * 100 + again[0][0] + again[1]["n"]


managed_entry()
