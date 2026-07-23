"""False / 0 cross-tag contains + subscript via DICT_COLLISION.

Requires EXCORE_EN=1. Store INT 0, then False in d / d[False] → 7.
"""


def managed_entry():
    d = {}
    d[0] = 7
    if False in d:
        return d[False]
    return 0


managed_entry()
