# Tests many local variable assignments and arithmetic involving pairs of locals.
# All binary operations use two local variables (exercises LOAD_FAST_BORROW pairs).
def managed_entry() -> int:
    w1 = 3
    v1 = 5
    a = w1 * v1     # 15: two-local multiply

    w2 = 7
    v2 = 2
    b = w2 * v2     # 14: two-local multiply

    w3 = 10
    v3 = 10
    c = w3 * v3     # 100: two-local multiply

    ab = a + b      # 29: two-local add
    return ab + c   # 129: two-local add
