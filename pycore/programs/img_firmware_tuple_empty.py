"""ROM tuple() with no args must return empty (None-default CALL fill).

Avoid list literals that emit LIST_EXTEND (needs excore). Iterable materialize
is covered by img_firmware_wave3_containers.

Host golden: 101.
"""


def managed_entry():
    t = tuple()
    total = 0
    if len(t) == 0:
        total += 100
    # Explicit None still binds correctly (non-wipe path).
    u = tuple(None)
    if len(u) == 0:
        total += 1
    return total


managed_entry()
