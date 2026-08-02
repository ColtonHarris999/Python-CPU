"""DICT_UPDATE via a `{**a, **b}` dict-unpack display.

Lowers to BUILD_MAP 0 + DICT_UPDATE per source. The second update grows the
4-slot dict past its 2/3 load factor, so both the in-place insert and the
grow-to-fit paths run (needs EXCORE_EN=1 / two-core). Duplicate key 2 is
overwritten by b (update semantics).
"""


def managed_entry():
    a = {1: 1, 2: 2}
    b = {2: 20, 3: 3}
    d = {**a, **b}
    return len(d) * 100 + d[1] + d[2] + d[3]


managed_entry()
