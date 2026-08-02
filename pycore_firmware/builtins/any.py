"""True if any element is truthy.

PyCore note: truthiness uses hardware TO_BOOL (None, INT/BOOL/FLOAT,
STR, LIST/TUPLE/DICT/SET, inline RANGE). OBJECT without ``__bool__``
still TYPE-traps.
"""


def any(iterable):
    for e in iterable:
        if e:
            result = True
            return result
    result = False
    return result
