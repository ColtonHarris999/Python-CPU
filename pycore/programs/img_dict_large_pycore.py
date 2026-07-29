"""Many INT keys via BUILD_MAP (locals force BUILD_MAP, not CONST_KEY_MAP).

8 pairs → 16 slots, used=8; stays under the 2/3 grow threshold. Stresses
same-tag probe/lookup without excore. Return sum of values.
"""


def managed_entry():
    k0 = 0
    v0 = 1
    k1 = 1
    v1 = 2
    k2 = 2
    v2 = 3
    k3 = 3
    v3 = 4
    k4 = 4
    v4 = 5
    k5 = 5
    v5 = 6
    k6 = 6
    v6 = 7
    k7 = 7
    v7 = 8
    d = {k0: v0, k1: v1, k2: v2, k3: v3, k4: v4, k5: v5, k6: v6, k7: v7}
    s = 0
    s = s + d[k0]
    s = s + d[k1]
    s = s + d[k2]
    s = s + d[k3]
    s = s + d[k4]
    s = s + d[k5]
    s = s + d[k6]
    s = s + d[k7]
    return s


managed_entry()
