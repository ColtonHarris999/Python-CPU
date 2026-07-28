"""DICT_UPDATE via {**a, **b} — always excore trap 15. Needs EXCORE_EN=1.

Build source dicts with STORE_SUBSCR (SMALL_INT keys) so lookup uses the
same key representation as img_dict_grow_basic.
Expected: result[1]+result[2]+result[3] = 10+20+30 = 60.
"""


def managed_entry():
    a = {}
    a[1] = 10
    a[2] = 20
    b = {}
    b[3] = 30
    result = {**a, **b}
    return result[1] + result[2] + result[3]


managed_entry()
