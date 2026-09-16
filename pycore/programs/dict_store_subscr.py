"""Build a dict {k: initial}, overwrite d[k] = newval, return d[k].

Locals force BUILD_MAP. Expected: INT 99.
"""


def managed_entry():
    k = 3
    v = 10
    d = {k: v}
    newval = 99
    d[k] = newval
    return d[k]


managed_entry()
