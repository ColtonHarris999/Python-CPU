"""True if any element is truthy.

PyCore note: truthiness uses TO_BOOL (INT/BOOL/FLOAT/STR only).
None and containers TYPE-trap — same as hardware TO_BOOL.
"""


def any(iterable):
    for e in iterable:
        if e:
            result = True
            return result
    result = False
    return result
