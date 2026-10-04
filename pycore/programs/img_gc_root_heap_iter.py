"""GC: HEAP_ITER over a user instance stays live across RF wrap (B9).

GET_ITER on a user object that returns self stores PY_ITER_KIND_HEAP_ITER
pointing at the instance. Deep recursion wraps the RF ring. Seed 11's
collection 399 traces that iterator to a zeroed instance header.
"""


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


def deep(n, acc):
    a = [n, acc]
    b = (n, a)
    if n == 0:
        return acc
    return deep(n - 1, acc + len(b))


def managed_entry():
    R0 = range(0, 1099511627776, 7)
    acc = 0
    for p in Counter(2):
        acc = acc + p[0]
        break
    for _ in range(4):
        for p in Counter(4):
            acc = acc + p[0] + len(p[1])
        acc = acc + deep(36, 0)
    return acc


managed_entry()
