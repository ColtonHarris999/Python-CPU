"""Insert past 2/3 load on a 4-slot empty dict → DICT_GROW, then verify.

BUILD_MAP 0 → 4 slots; fourth new-key insert traps grow. Needs EXCORE_EN=1.
"""


def managed_entry():
    d = {}
    d[0] = 1
    d[1] = 2
    d[2] = 3
    d[3] = 4
    return d[0] + d[1] + d[2] + d[3]


managed_entry()
