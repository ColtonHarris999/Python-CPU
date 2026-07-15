"""Insert until table would fill completely → MEM_FAULT (must not hang).

2 pairs → 4 slots. After BUILD_MAP used=2. Insert key 2 → used=3.
Insert key 3 would make used=4 (100% full) → trap.
"""

def managed_entry() -> int:
    d = {0: 10, 1: 20}
    d[2] = 30
    d[3] = 40  # should trap: would fill last empty slot
    return 0
