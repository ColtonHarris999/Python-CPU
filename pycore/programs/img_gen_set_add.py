"""GC gen Phase 0: set.add and set.update of young objects on an old set.

A set survives a collection, then gets freshly allocated strings by add
(enough to grow the table) and by update from a list and a tuple. A second
collection runs before membership and contents are folded into the checksum.
"""


def key(n):
    return "young-set-member-" + str(n)


def managed_entry():
    old = {"old-a", "old-b"}
    _bi_gc_collect()
    for i in range(30):
        old.add(key(i))
    old.update([key(200), key(201)])
    old.update((key(300), key(301)))
    junk = key(999)
    junk = None
    _bi_gc_collect()
    total = len(old)
    for i in range(30):
        if key(i) in old:
            total = total + i + 1
    for k in (key(200), key(201), key(300), key(301)):
        if k in old:
            total = total + 100
    for m in old:
        total = total + len(m)
    return total


managed_entry()
