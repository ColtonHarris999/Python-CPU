"""Yield (index, item) pairs — returns a list (no generators/YIELD).

Deviation: materializes all pairs instead of returning an enumerate
iterator object.
"""


def enumerate(iterable, start=0):
    out = []
    i = start
    for x in iterable:
        out += [(i, x)]
        i = i + 1
    return out
