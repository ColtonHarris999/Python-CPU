"""INT-pair tuple dict keys — PyBGL memoize.get((i, j)) / store.

Store and lookup use distinct tuple objects so identity hash would miss.
Two unique keys stay under the empty-dict 2/3 grow threshold.
Expected: 617 (7 + 10*11 + 100*5).
"""


def managed_entry():
    d = {}
    d[(0, 0)] = 1
    d[(0, 0)] = 7
    d[(1, 2)] = 11
    a = d.get((0, 0))
    b = d.get((1, 2))
    miss = d.get((3, 4), 5)
    return a + 10 * b + 100 * miss


managed_entry()
