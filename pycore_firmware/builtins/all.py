"""True if every element is truthy (or iterable is empty).

PyCore note: truthiness uses TO_BOOL (INT/BOOL/FLOAT/STR only).
None and containers TYPE-trap — same as hardware TO_BOOL.
"""


def all(iterable):
    for e in iterable:
        if not e:
            result = False
            return result
    result = True
    return result
