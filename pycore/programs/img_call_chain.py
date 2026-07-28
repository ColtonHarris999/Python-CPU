def add(a, b):
    return a + b


def double(x):
    return add(x, x)


def managed_entry():
    return double(21)


managed_entry()
