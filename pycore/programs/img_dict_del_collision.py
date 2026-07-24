"""Cross-tag delete: store INT 1, del True via pycore rich_eq.

Returns 0 when the key is gone (single-core).
"""


def managed_entry():
    d = {}
    d[1] = 5
    del d[True]
    if 1 not in d:
        return 0
    return 1


managed_entry()
