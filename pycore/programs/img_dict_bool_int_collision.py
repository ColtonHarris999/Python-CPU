"""INT/BOOL cross-tag STORE: d[1]=10 then d[True]=20 overwrites via COLLISION.

Requires EXCORE_EN=1 (DICT_COLLISION). CPython: True == 1 → one entry, value 20.
"""


def managed_entry():
    d = {}
    d[1] = 10
    d[True] = 20
    return d[1]


managed_entry()
