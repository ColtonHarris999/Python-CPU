# Exercises UNARY_NEGATIVE on INT, BOOL, and FLOAT.
# Score: (-3)==-3 → +1; (-True)==-1 → +2; (-1.5)<0 → +4. Host golden 7.


def managed_entry():
    y = 3
    t = True
    z = 1.5
    out = 0
    if (-y) == -3:
        out += 1
    if (-t) == -1:
        out += 2
    if (-z) < 0.0:
        out += 4
    return out


managed_entry()
