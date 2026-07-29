# Exercises UNARY_INVERT on INT and BOOL (BOOL promotes to INT).
# ~5 == -6, ~True == -2 → host golden -8.


def managed_entry():
    x = 5
    t = True
    return (~x) + (~t)


managed_entry()
