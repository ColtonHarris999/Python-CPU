"""Iterator edge cases: empty list, single element, sequential loop reuse.

Expected result: 0 + 7 + 1 + 2 + 3 = 13.
"""


def managed_entry():
    total = 0

    empty = []
    for x in empty:
        total += 1000

    d = 7
    for x in [d]:
        total += x

    for x in [1]:
        total += x
    for x in [2, 3]:
        total += x

    return total


managed_entry()
