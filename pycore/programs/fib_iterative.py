def managed_entry() -> int:
    a = 0
    b = 1
    n = 10
    while n > 0:
        nxt = a + b
        a = b
        b = nxt
        n = n - 1
    return a
