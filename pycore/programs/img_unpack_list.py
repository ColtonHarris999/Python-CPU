# UNPACK_SEQUENCE on a LIST local (count=2).
# a,b = [4,5] → 9.


def managed_entry():
    xs = [4, 5]
    a, b = xs
    return a + b


managed_entry()
