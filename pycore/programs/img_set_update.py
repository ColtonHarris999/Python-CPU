"""SET_UPDATE via {*s, *xs} — always excore trap 14. Needs EXCORE_EN=1."""


def managed_entry():
    a = 1
    s = {a}
    xs = [2, 3]
    t = {*s, *xs}
    n = 0
    if 1 in t:
        n = n + 1
    if 2 in t:
        n = n + 1
    if 3 in t:
        n = n + 1
    return n


managed_entry()
