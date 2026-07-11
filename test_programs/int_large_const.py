# Tests LOAD_CONST with large integer values that exceed LOAD_SMALL_INT range
# and verifies arithmetic on them.
def managed_entry() -> int:
    a = 1000000
    b = 999999
    c = a + b        # 1999999
    d = c * 2        # 3999998
    e = d // 1000    # 3999
    return e
