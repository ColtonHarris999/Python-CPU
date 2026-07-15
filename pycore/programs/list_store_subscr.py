"""Build a three-element list, overwrite element [1] with STORE_SUBSCR, return it.

Expected result: INT 42
"""


def managed_entry() -> int:
    x = 1
    y = 2
    z = 3
    lst = [x, y, z]
    lst[1] = 42
    return lst[1]
