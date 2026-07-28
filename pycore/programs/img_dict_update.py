"""DICT_UPDATE via {**a, **b} — always excore trap 15. Needs EXCORE_EN=1.

{**a, **b} merges two dicts. We verify the result contains keys from both.
Expected: result[1]+result[2]+result[3] = 10+20+30 = 60.
"""


def managed_entry():
    a = {1: 10, 2: 20}
    b = {3: 30}
    result = {**a, **b}
    return result[1] + result[2] + result[3]


managed_entry()
