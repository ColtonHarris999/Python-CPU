"""Delete then contains on the same list."""


def managed_entry():
    x0 = 5
    x1 = 6
    x2 = 7
    x3 = 8
    a = [x0, x1, x2, x3]
    del a[1]
    # now [5, 7, 8]
    n = 0
    if 6 not in a:
        n = n + 1
    if 7 in a:
        n = n + 2
    if a[0] + a[1] + a[2] == 20:
        n = n + 4
    return n


managed_entry()
