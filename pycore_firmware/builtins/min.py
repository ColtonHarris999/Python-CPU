"""Smallest item of an iterable, or of two or more arguments.

Signature: ``min(iterable)`` or ``min(a, b, *rest)``. ``key=`` / ``default=``
remain deferred. Empty iterable returns None (CPython raises ValueError).
Zero arguments raise TypeError. Native BI_MAX remains for bare ``max(a, b)``.
"""


def min(*args):
    n = len(args)
    if n == 0:
        raise TypeError
    if n == 1:
        best = None
        seen = 0
        for x in args[0]:
            if seen == 0:
                best = x
                seen = 1
            else:
                if x < best:
                    best = x
        return best
    best = args[0]
    i = 1
    while i < n:
        x = args[i]
        if x < best:
            best = x
        i = i + 1
    return best
