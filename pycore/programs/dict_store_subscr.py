"""Build a dict {k: initial}, overwrite d[k] = newval, return d[k].

Expected result: INT 99
"""


def managed_entry() -> int:
    k = 3
    v = 10
    d = {k: v}
    newval = 99
    d[k] = newval
    return d[k]
