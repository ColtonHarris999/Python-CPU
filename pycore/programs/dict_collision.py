"""Two keys that collide under hash & (slot_count-1); look up both.

2 pairs → slot_count 4; 0 and 4 both hash to slot 0. Expected: INT 30.
"""


def managed_entry():
    k0 = 0
    v0 = 10
    k1 = 4
    v1 = 20
    d = {k0: v0, k1: v1}
    a = d[k0]
    b = d[k1]
    return a + b


managed_entry()
