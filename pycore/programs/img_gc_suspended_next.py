"""GC: a collection inside __next__ keeps the suspended outer iteration (gc_plan.md §6.4).

FOR_ITER over a user iterator calls __next__ as a protocol call; while it
runs, the iterator object is held by the container-call register bank. The
iterator is created inline, so nothing else references it, and __next__
allocates and collects.
"""


class Walker:
    def __init__(self, items):
        self.items = items
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self.i >= len(self.items):
            raise StopIteration
        _bi_gc_collect()
        v = self.items[self.i]
        self.i = self.i + 1
        junk = [v, v, v]
        junk = None
        _bi_gc_collect()
        return (v, "next-result-" + str(v))


def managed_entry():
    total = 0
    for v, s in Walker([4, 5, 6, len("abcdefg")]):
        total = total + v * 10 + len(s)
    return total


managed_entry()
