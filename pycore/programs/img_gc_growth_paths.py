"""Phase 3: every excore growth path after leftover is short (gc_plan.md §6.4).

List-comprehension LIST_APPEND, in-place LIST_EXTEND, dict STORE grow, and
SET_UPDATE each run after dropped tuples leave a grant too small to bump.
Host `_bi_heap_free` is 0, so the fill is a no-op and the checksum is 18.
"""


def managed_entry():
    drop = None
    while _bi_heap_free() >= 1024:
        drop = (drop, 1)
    drop = None
    xs = [x for x in (1, 2)]
    xs += (3, 4)
    d = {}
    d[0] = 1
    d[1] = 2
    d[2] = 3
    d[3] = 4
    d[4] = 5
    d[5] = 6
    d[6] = 7
    d[7] = 8
    s = {0}
    s = {*s, 1, 2, 3, 4}
    return xs[0] + xs[3] + d[7] + len(s)


managed_entry()
