"""Insert until load would fill / exceed grow threshold → DICT_GROW.

2 pairs → 4 slots. After BUILD_MAP used=2. Insert key 2 → used=3.
Insert key 3 would make used+1 >= slot_count → PY_TRAP_DICT_GROW.
"""

def managed_entry() -> int:
    d = {0: 10, 1: 20}
    d[2] = 30
    d[3] = 40  # should trap: would fill last empty slot
    return 0
