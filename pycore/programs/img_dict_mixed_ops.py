"""End-to-end: grow + collision + delete + contains + CALL.

Requires EXCORE_EN=1.
"""


def helper(d):
    # Overwrite key 1 via BOOL collision; delete key 0 via False.
    d[True] = 20
    del d[False]
    n = 0
    if 1 in d:
        n = n + d[1]
    if 0 not in d:
        n = n + 100
    if 2 in d:
        n = n + d[2]
    if 3 in d:
        n = n + d[3]
    if 4 in d:
        n = n + d[4]
    return n


def managed_entry():
    d = {}
    d[0] = 1
    d[1] = 2
    d[2] = 3
    d[3] = 4
    d[4] = 5
    return helper(d)


managed_entry()
