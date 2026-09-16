"""Build a 4-pair dict and look up each key; return last lookup.

Locals force BUILD_MAP. Expected: INT 100.
"""


def managed_entry():
    k1 = 1
    v1 = 10
    k2 = 2
    v2 = 20
    k3 = 3
    v3 = 30
    k4 = 4
    v4 = 40
    d = {k1: v1, k2: v2, k3: v3, k4: v4}
    a = d[k1]
    b = d[k2]
    c = d[k3]
    e = d[k4]
    return a + b + c + e


managed_entry()
