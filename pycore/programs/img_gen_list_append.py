"""GC gen Phase 0: append/extend young objects onto an old list.

The list is built and survives a collection, then gets young objects by
append within spare capacity, append past capacity (the element buffer moves),
and extend. After a second collection every element is read back.
"""


def fresh(n):
    return ["appended-young-object-" + str(n), n]


def managed_entry():
    old = []
    for i in range(5):
        old.append(("old-" + str(i), i))
    _bi_gc_collect()
    # Within whatever capacity the five appends left.
    old.append(fresh(5))
    old.append(fresh(6))
    _bi_gc_collect()
    # Well past capacity: the buffer is reallocated while the list is old.
    for i in range(7, 40):
        old.append(fresh(i))
    old.extend([fresh(40), fresh(41), (fresh(42), "tuple-wrapped")])
    old.extend(fresh(43))
    tmp = fresh(1000)
    tmp = None
    _bi_gc_collect()
    total = len(old)
    for i in range(5):
        total = total + len(old[i][0]) + old[i][1]
    for i in range(5, 42):
        total = total + len(old[i][0]) * 3 + old[i][1]
    total = total + len(old[42][0][0]) + len(old[42][1])
    total = total + len(old[43]) + old[44]
    return total


managed_entry()
