"""Positional-only + **kwargs: keyword matching posonly name goes to kwargs."""


def f(a, /, b=0, **k):
    # f(1, a=2) → a=1, b=0, k={'a':2}
    return a + 10 * b + (0 if len(k) == 0 else 100 * k["a"])


def managed_entry():
    return f(1, a=2) + f(3, b=4)


managed_entry()
