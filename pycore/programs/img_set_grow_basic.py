"""SET_ADD past 2/3 load → SET_GROW, then verify contains. Needs EXCORE_EN=1."""

# pycore-inject: SET_ADD_SEQ managed_entry 0 1 2 3 MODE=CONTAINS


def managed_entry():
    s = set()
    s.add(0)
    s.add(1)
    s.add(2)
    s.add(3)
    n = 0
    if 0 in s:
        n = n + 1
    if 1 in s:
        n = n + 1
    if 2 in s:
        n = n + 1
    if 3 in s:
        n = n + 1
    if 4 not in s:
        n = n + 1
    return n


managed_entry()
