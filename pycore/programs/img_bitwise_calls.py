# Bitwise / arithmetic helpers composed across several CALL layers.
# Covers << >> & | ^ mixed with compares and early returns.

def pack(hi, lo):
    return (hi << 4) | (lo & 15)


def scramble(x):
    return ((x << 1) ^ (x >> 2)) + (x & 7)


def clamp_nibble(x):
    if x < 0:
        return 0
    if x > 15:
        return 15
    return x


def pipeline(a, b, c):
    p = pack(a, b)
    s = scramble(p)
    return clamp_nibble(s) + clamp_nibble(c)


def managed_entry():
    return pipeline(3, 9, 20) + pipeline(1, 1, -2)


managed_entry()
