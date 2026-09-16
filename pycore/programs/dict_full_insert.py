"""Insert until load would fill / exceed grow threshold → DICT_GROW.

2 pairs → 4 slots. After BUILD_MAP used=2. Insert key 2 → used=3.
Insert key 3 would make used+1 >= slot_count → PY_TRAP_DICT_GROW.
"""


def managed_entry():
    k0 = 0
    v0 = 10
    k1 = 1
    v1 = 20
    d = {k0: v0, k1: v1}
    d[2] = 30
    d[3] = 40
    return 0


managed_entry()
