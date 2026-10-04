"""len(instance) whose __len__ takes **kwargs (review round 1, finding 2).

`len(x)` on an instance rewrites the callable slot with `__len__` and the
NULL slot with `x`, then reserves the binder's `**kw` dict. When that
reservation aborts, the unwind must restore both slots, or the re-dispatched
CALL runs `__len__(x, x)`.
"""


class Bag:
    def __init__(self, n):
        self.n = n

    def __len__(self, **kw):
        return self.n + len(kw)


def managed_entry():
    total = 0
    for i in range(200):
        b = Bag(i % 9)
        total = total + len(b)
    return total


managed_entry()
