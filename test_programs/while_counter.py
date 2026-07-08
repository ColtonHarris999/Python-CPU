# Tests while loop with a sum accumulator — exercises loop counter, branch back.
def managed_entry() -> int:
    total = 0
    i = 1
    while i <= 10:
        total = total + i
        i = i + 1
    return total  # sum 1..10 = 55
