# Tests boolean values used in arithmetic (bool promotes to int or float).
# True == 1, False == 0 in arithmetic contexts.
def managed_entry() -> int:
    t = True
    f = False
    a = t + t        # 2
    b = t + 5        # 6
    c = f + 10       # 10
    d = t * 7        # 7
    return a + b + c + d  # 25
