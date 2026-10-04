"""Phase 3 G9: ≥10 NEED_HEAP abort/collect/re-dispatch events per excore row.

Each iteration fills the grant with dropped tuples, then LIST_APPEND grow,
LIST_EXTEND, dict STORE grow, and SET_UPDATE. Host `_bi_heap_free` is 0 so
the fill is a no-op and the checksum is 180.
"""


def managed_entry():
    total = 0
    n = 0
    while n < 20:
        drop = None
        while _bi_heap_free() >= 256:
            drop = (drop, 1)
        drop = None
        xs = [x for x in (1, 2)]
        xs += (3,)
        d = {}
        d[0] = 1
        d[1] = 2
        s = {0}
        s = {*s, 1, 2}
        total = total + xs[0] + xs[2] + d[1] + len(s)
        n = n + 1
    return total


managed_entry()
