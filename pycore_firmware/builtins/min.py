"""Smallest item of an iterable, or of two arguments.

Signature: ``min(iterable)`` or ``min(a, b)``. Varargs / key= / default=
need CO_VARARGS or further CALL_KW work. Empty iterable returns None
(CPython raises ValueError). Native BI_MAX remains for bare ``max(a, b)``.
"""


def min(a, b=None):
    if b is not None:
        if a <= b:
            return a
        return b
    best = None
    seen = 0
    for x in a:
        if seen == 0:
            best = x
            seen = 1
        else:
            if x < best:
                best = x
    return best
