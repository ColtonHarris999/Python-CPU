"""Deleting an upcoming element shifts the live list and skips that element.

After yielding 1, deleting index 1 changes [1,2,3,4] to [1,3,4].
The iterator continues at index 1 and yields 3,4. Expected sum: 8.
"""


def managed_entry():
    a = 1
    b = 2
    c = 3
    d = 4
    xs = [a, b, c, d]
    total = 0
    for x in xs:
        total += x
        if x == 1:
            del xs[1]
    return total


managed_entry()
