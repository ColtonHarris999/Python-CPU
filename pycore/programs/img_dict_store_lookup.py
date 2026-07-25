"""STORE_SUBSCR + NB_SUBSCR on an empty dict (same-tag INT).

BUILD_MAP 0 allocates 4 slots; three inserts stay under the 2/3 grow
threshold. Return checksum of looked-up values.
"""


def managed_entry():
    d = {}
    d[1] = 10
    d[2] = 20
    d[3] = 30
    return d[1] + d[2] + d[3]


managed_entry()
