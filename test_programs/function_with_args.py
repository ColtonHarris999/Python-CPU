# Tests function calls with multiple integer arguments and local computation.
# managed_entry calls weighted_sum twice and sums the results.
def managed_entry() -> int:
    a = weighted_sum(3, 5, 7, 2)   # 3*5 + 7*2 = 15 + 14 = 29
    b = weighted_sum(1, 0, 10, 10) # 1*0 + 10*10 = 0 + 100 = 100
    return a + b  # 129


def weighted_sum(w1: int, v1: int, w2: int, v2: int) -> int:
    return w1 * v1 + w2 * v2
