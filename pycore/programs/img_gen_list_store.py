"""GC gen Phase 0: `old[i] = fresh` stores young objects into an old list.

The list survives a collection (so it is old), then each slot is overwritten
with a freshly allocated list/tuple/str. Other references are dropped and a
second collection runs; reading every slot back must still see the young
objects.
"""


def fresh(n):
    return ["young-list-item-" + str(n), (n, n * 3)]


def fold(old):
    total = 0
    for i in range(len(old)):
        item = old[i]
        total = total + len(item[0]) * (i + 1) + item[1][0] + item[1][1]
    return total


def managed_entry():
    old = [None] * 16
    for i in range(16):
        old[i] = ("old-placeholder", i)
    _bi_gc_collect()
    for i in range(16):
        old[i] = fresh(i)
    for i in range(0, 16, 3):
        old[i] = fresh(i + 100)
    garbage = fresh(999)
    garbage = None
    _bi_gc_collect()
    _bi_gc_collect()
    return fold(old)


managed_entry()
