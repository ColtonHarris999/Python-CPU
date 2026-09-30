# Compile suite: shapes the peephole pass rewrites. LOAD_FAST pairs,
# STORE_FAST/LOAD_FAST, STORE_FAST pairs and `is None` jumps -- including a
# deleted-then-rebound local, which must not be fused as if bound.
def pairs(a, b):
    c = a + b
    d = c
    x, y = b, a
    return c * 100 + d * 10 + x - y


def none_checks(v):
    n = 0
    if v is None:
        n += 1
    if v is not None:
        n += 10
    while v is not None:
        v = None
        n += 100
    return n


def rebind(a):
    del a
    a = 7
    b = a
    return a + b


def swap_loop(k):
    lo = 0
    hi = k
    while lo < hi:
        lo, hi = lo + 1, hi - 1
    return lo * 10 + hi


print("pairs", pairs(3, 4))
print("none", none_checks(None), none_checks(5))
print("rebind", rebind(1))
print("swap", swap_loop(9))
