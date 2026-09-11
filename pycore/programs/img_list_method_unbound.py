"""Unbound native method form: f = xs.append; f(7). Two-core. Expected: 7."""


def managed_entry():
    xs = []
    f = xs.append
    f(7)
    return xs[0]


managed_entry()
