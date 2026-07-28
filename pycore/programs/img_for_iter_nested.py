"""Nested LIST/TUPLE for-loops — two stacked iterators.

Expected result: 1*10 + 1*20 + 2*10 + 2*20 = 90.
"""


def managed_entry():
    total = 0
    for a in [1, 2]:
        for b in [10, 20]:
            total += a * b
    return total


managed_entry()
