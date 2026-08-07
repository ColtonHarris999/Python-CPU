"""CO_VARARGS with keyword-only binding through CALL_KW."""


def f(*a, s=1):
    return len(a) * 10 + s


def managed_entry():
    return f(9, s=2)


managed_entry()
