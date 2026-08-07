"""CO_VARARGS with CALL_FUNCTION_EX star expansion."""


def f(*a):
    return len(a)


def managed_entry():
    return f(*(1, 2))


managed_entry()
