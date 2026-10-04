"""Two-core G9 rows 15 and 17, plus STORE_ATTR / MAP_ADD growth (row 14).

Before each growth the loop fills the current grant with dropped tuples, so
the excore grant (SET_ADD grow; MAP_ADD and STORE_ATTR instance-dict grow)
and PyCore's bulk dict build answer NEED_HEAP or abort, collect, and
re-dispatch. `{**a, **b}` with an instance key is contaminated, so it stays
on PyCore's bulk path (row 17) instead of trapping to excore. Host
`_bi_heap_free` is 0, so the fill is a no-op on CPython.
"""


class Rec:
    def __init__(self, i):
        self.a = i


def fill(room):
    # `_bi_heap_free` also counts alignment pads no allocation can use, so
    # filling can exhaust the usable runs while the chain is still live.
    # That MemoryError is part of the churn: drop the chain and go on.
    try:
        drop = None
        while _bi_heap_free() >= room:
            drop = (drop, 1)
    except MemoryError:
        drop = None
    return drop is None


def managed_entry():
    total = 0
    n = 0
    while n < 60:
        fill(256)
        s = {k + n for k in range(10)}
        r = Rec(n)
        a = {r: 1, n: 2, n + 10: 3, n + 11: 4, n + 12: 5, n + 13: 6, n + 14: 7, n + 15: 8}
        b = {n + 1: 3, n + 2: 4, n + 3: 5}
        # Room for the empty BUILD_MAP's dict and table, not for the table
        # DICT_UPDATE grows to (768 left BUILD_MAP itself collecting).
        fill(1400)
        u = {**a, **b}
        fill(256)
        r.b = n + 1
        r.c = n + 2
        r.d = n + 3
        fill(256)
        m = {k: k * 2 for k in range(n % 3, n % 3 + 9)}
        total = total + len(s) + len(u) + r.d + len(m)
        n = n + 1
    return total


managed_entry()
