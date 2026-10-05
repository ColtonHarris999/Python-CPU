"""GC: reference cycles, live and dead (gc_plan.md Phase 0).

Each round builds two instances that point at each other and a list that
contains itself. One round is kept; the rest become unreachable cycles, which
a tracing collector must reclaim (reference counting would not).
"""


class Node:
    def __init__(self, v):
        self.v = v
        self.other = None


def make_cycle(v):
    a = Node(v)
    b = Node(v + 1)
    a.other = b
    b.other = a
    lst = [a, b, None]
    lst[2] = lst
    return lst


def managed_entry():
    keep = make_cycle(1)
    tmp = None
    for i in range(4):
        tmp = make_cycle(i * 10)
    tmp = None
    _bi_gc_collect()
    total = keep[0].v + keep[1].other.v + len(keep[2]) * 100
    _bi_gc_collect()
    return total + keep[0].other.other.v + keep[2][2][0].v


managed_entry()
