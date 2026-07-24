"""INT/BOOL cross-tag STORE: d[1]=10 then d[True]=20 overwrites via rich_eq.

Rich equality runs on pycore (single-core). CPython: True == 1 → value 20.
"""


def managed_entry():
    d = {}
    d[1] = 10
    d[True] = 20
    return d[1]


managed_entry()
