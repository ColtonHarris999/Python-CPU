"""CALL_FUNCTION_EX *args with tuple (NULL kwargs)."""


def g(a, b, c):
    return a + 10 * b + 100 * c


def managed_entry():
    return g(*(1, 2, 3))


managed_entry()
