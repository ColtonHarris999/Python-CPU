"""Image-boot parity coverage for LIST/TUPLE iteration.

The list is built from locals so CPython emits BUILD_LIST rather than folding
the iterable to a tuple.  The empty tuple exercises immediate exhaustion.
Expected result: 1+2+3+4+5 = 15.
"""


def managed_entry():
    a = 1
    b = 2
    c = 3
    xs = [a, b, c]

    total = 0
    for x in xs:
        total += x
    for x in (4, 5):
        total += x
    for x in ():
        total += 100
    return total


managed_entry()
