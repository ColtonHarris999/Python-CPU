"""BINARY_SLICE on TUPLE: same clamp/copy rules as LIST, new tuple result."""


def managed_entry():
    one = 1
    two = 2
    three = 3
    zero = 0
    xs = (one, two, three)
    a = xs[zero:two]
    b = xs[one:three]
    return a[0] + 10 * a[1] + 100 * b[1]


managed_entry()
