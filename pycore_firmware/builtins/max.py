"""Largest item of an iterable, or of two arguments.

Signature limited to (iterable) or (a, b) — *args / key= / default=
need CALL_FUNCTION_EX / CALL_KW (deferred).
Empty iterable returns None (CPython raises ValueError; RAISE deferred).
Native BI_MAX currently handles the two-arg form on-core.
"""


def max(a, b=None):
    if b is not None:
        if a >= b:
            return a
        return b
    best = None
    seen = 0
    for x in a:
        if seen == 0:
            best = x
            seen = 1
        else:
            if x > best:
                best = x
    return best
