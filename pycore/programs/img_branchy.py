def managed_entry():
    n = 8
    total = 0
    while n:
        if n & 1:
            total += n
        else:
            total += 2
        n -= 1
    return total


managed_entry()
