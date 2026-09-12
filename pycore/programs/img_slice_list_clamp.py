"""Out-of-range LIST slice bounds clamp like CPython."""


def managed_entry():
    one = 1
    two = 2
    nine = 9
    zero = 0
    xs = [one, two]
    a = xs[one:nine]
    b = xs[nine:nine]
    c = xs[zero:nine]
    return a[0] + 10 * len(a) + 100 * len(b) + 1000 * len(c)


managed_entry()
