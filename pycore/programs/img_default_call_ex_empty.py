"""All-defaults via CALL_FUNCTION_EX empty *args / **kwargs."""


def f(a=None, b=0):
    if a is None:
        return 10 + b
    return a + b


def managed_entry():
    x = f(*())
    y = f(*[], **{})
    z = f(*(7,), **{"b": 1})
    return x + y + z


managed_entry()
