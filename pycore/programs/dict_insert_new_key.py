"""Build {1:10}, then d[2]=20, return d[2]. Expected: INT 20.

Locals force BUILD_MAP.
"""


def managed_entry():
    k = 1
    v = 10
    d = {k: v}
    d[2] = 20
    return d[2]


managed_entry()
