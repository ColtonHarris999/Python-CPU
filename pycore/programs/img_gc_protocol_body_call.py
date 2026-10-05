"""An allocating CALL inside a protocol method body collects instead of
faulting.

`__next__` runs as a container-launched protocol call. Before review round 2
every CALL in its body (here `Rec(...)`, an instance allocation) was treated
as the launch itself, which has no undo record, so a short run trapped 7
with garbage on the heap. Only the launch is exempt from unwinding now.

# pycore-expect: 20100
"""


class Rec:
    def __init__(self, v):
        self.v = v


class Counter:
    def __init__(self, n):
        self.i = 0
        self.n = n

    def __iter__(self):
        return self

    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i = self.i + 1
        return Rec(self.i)


def managed_entry():
    total = 0
    for r in Counter(200):
        total = total + r.v
    return total


managed_entry()
