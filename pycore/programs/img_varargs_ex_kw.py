"""CO_VARARGS + CALL_FUNCTION_EX kwargs; fills remaining kw-only defaults."""


def f(*a, x=1, y=2):
    return len(a) * 1000 + x * 100 + y


def managed_entry():
    xs = (7, 8)
    return f(*xs, x=3)


managed_entry()
