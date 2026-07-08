# Tests function calls with multiple integer arguments and local computation.
def managed_entry() -> int:
    a = weighted_sum(3, 5, 7, 2)
    b = weighted_sum(1, 0, 10, 10)
    return a + b  # (3*5 + 7*2) + (1*0 + 10*10) = (15+14) + 100 = 129


def weighted_sum(w1: int, v1: int, w2: int, v2: int) -> int:
    return w1 * v1 + w2 * v2
