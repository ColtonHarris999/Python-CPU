"""GC: protocol CALL must not treat a stale rs2 latch as a live list (G8).

FOR_ITER HEAP_ITER used to snapshot rs2_r into container_call_saved_rs2_r.
rs2 is dead at a GC boundary and often still holds a recently popped list.
Seed 11 measure collection 29 followed that handle to a poisoned LIST header
and marked the rest of the heap.
"""


class Box:
    def __init__(self, kind, val):
        self.kind = kind
        self.val = val


class Node:
    def __init__(self, a, b):
        self.a = a
        self.b = b


class Counter:
    def __init__(self, n):
        self.n = n
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i = self.i + 1
        return (self.i, "item-number-" + str(self.i))


def managed_entry():
    acc = 0
    L1 = [Box(0, 1), Box(7, None), Box(0, 2)]
    D0 = {"a": Box(0, 0), "b": Box(7, None)}
    for _ in range(3):
        tmp = [Box(4, D0), L1[0], Box(0, acc), Box(2, L1)]
        D0["b"] = Box(7, None)
        L1[1] = Box(0, acc)
        N1 = Node(Box(4, D0), Box(2, L1))
        tmp = None
        for p in Counter(4):
            acc = acc + p[0] + len(p[1])
        acc = acc + N1.a.kind
    return acc


managed_entry()
