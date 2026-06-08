def managed_entry() -> int:
    a0 = 5
    a1 = 1
    a2 = 4
    a3 = 2

    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp
    if a1 > a2:
        tmp = a1
        a1 = a2
        a2 = tmp
    if a2 > a3:
        tmp = a2
        a2 = a3
        a3 = tmp
    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp
    if a1 > a2:
        tmp = a1
        a1 = a2
        a2 = tmp
    if a0 > a1:
        tmp = a0
        a0 = a1
        a1 = tmp

    return a0 + a1 + a2 + a3
