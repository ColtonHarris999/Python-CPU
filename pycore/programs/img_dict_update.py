"""DICT_UPDATE via {**a, **b} — always excore trap 15. Needs EXCORE_EN=1.

Expected: result[1]+result[2]+result[3] = 10+20+30 = 60.
Keep names opaque enough that CPython 3.14 still emits DICT_UPDATE.
"""


def managed_entry():
    # Build via stores so keys are SMALL_INT on both insert and lookup paths
    # (matches img_dict_grow_basic / img_map_add style).
    a = {}
    a[1] = 10
    a[2] = 20
    b = {}
    b[3] = 30
    # Two star-unpacks force DICT_UPDATE; do not fold into one BUILD_MAP.
    result = {}
    result = {**result, **a}
    result = {**result, **b}
    return result[1] + result[2] + result[3]


managed_entry()
