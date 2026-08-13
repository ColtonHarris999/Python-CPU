"""Required kw-only missing while extras would go to **kwargs → CALL_FILTER."""


def f(*, x, **k):
    return x + len(k)


def managed_entry():
    return f(y=1)


managed_entry()
