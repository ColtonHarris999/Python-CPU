# UNPACK_SEQUENCE on a TUPLE local (count=3).
# a,b,c = (1,2,3) → 6.


def managed_entry():
    t = (1, 2, 3)
    a, b, c = t
    return a + b + c


managed_entry()
