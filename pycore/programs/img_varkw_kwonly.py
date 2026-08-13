"""Keyword-only formals + **kwargs packing together."""


def f(*, x=1, **k):
    return x + 10 * len(k) + (0 if len(k) == 0 else k["y"])


def managed_entry():
    # f(x=2, y=3) → 2 + 10 + 3 = 15; f() → 1
    return f(x=2, y=3) + f()


managed_entry()
