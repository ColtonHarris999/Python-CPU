"""False / 0 cross-tag contains + subscript via pycore rich_eq.

Store INT 0, then False in d / d[False] → 7 (single-core).
"""


def managed_entry():
    d = {}
    d[0] = 7
    if False in d:
        return d[False]
    return 0


managed_entry()
