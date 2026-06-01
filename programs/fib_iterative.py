def managed_entry() -> int:
    n = 12
    a = 0
    b = 1
    i = 0
    while i < n:
        nxt = a + b
        a = b
        b = nxt
        i += 1
    return a
