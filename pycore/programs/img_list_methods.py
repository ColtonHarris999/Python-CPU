"""Native list methods: append, extend, pop, clear.

append/extend use LIST_EXTEND (two-core). Expected: 10.
"""


def managed_entry():
    xs = []
    xs.append(10)
    xs.append(20)
    xs.extend([5])
    a = xs.pop()
    xs.clear()
    xs.append(4)
    return a + xs[0] + len(xs)


managed_entry()
