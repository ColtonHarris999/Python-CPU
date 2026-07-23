"""Cross-tag delete: store INT 1, del True via DICT_COLLISION.

Requires EXCORE_EN=1. Returns 0 when the key is gone.
"""


def managed_entry():
    d = {}
    d[1] = 5
    del d[True]
    if 1 not in d:
        return 0
    return 1


managed_entry()
