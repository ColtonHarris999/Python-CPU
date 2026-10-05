"""GC: values reachable only from spilled RF slots survive (gc_plan.md §6.4).

Deep recursion with several live locals per frame pushes the caller frames'
stack slots out of the 256-entry RF ring into the spill region. Each frame
owns a fresh list; the collection at the bottom must keep all of them.
"""


def dive(n):
    mine = [n, "frame-owned-string-" + str(n), (n, n + 1)]
    a = n * 2
    b = n * 3
    c = n + 7
    if n == 0:
        _bi_gc_collect()
        junk = [a, b, c]
        junk = None
        _bi_gc_collect()
        return len(mine[1])
    below = dive(n - 1)
    return below + mine[0] + len(mine[1]) + mine[2][1] + a + b + c


def managed_entry():
    return dive(48)


managed_entry()
