"""Native set.add / set.update. Needs SET_GROW (two-core). Expected: 4."""


def managed_entry():
    s = set()
    s.add(1)
    s.add(2)
    s.add(1)
    extra = 3
    s.update([extra])
    n = 0
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
