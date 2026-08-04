"""True if every element is truthy (or iterable is empty).

PyCore note: truthiness uses hardware TO_BOOL (None, INT/BOOL/FLOAT,
STR, LIST/TUPLE/DICT/SET, inline RANGE). OBJECT without ``__bool__``
still TYPE-traps.
"""


def all(iterable):
    for e in iterable:
        if not e:
            result = False
            return result
    result = True
    return result
