"""DICT_UPDATE simple test: merge two single-entry dicts.

Uses simpler dicts to test the basic merge.
Expected: result[1]+result[2] = 10+20 = 30.
"""


def managed_entry():
    a = {1: 10}
    b = {2: 20}
    result = {**a, **b}
    return result[1] + result[2]


managed_entry()
