"""Full CPython call shape: defaults, *args, kw-only, **kwargs."""


def f(a=0, *args, b=1, **k):
    return a + 10 * len(args) + 100 * b + 1000 * len(k) + (
        0 if len(k) == 0 else k["z"]
    )


def managed_entry():
    # f(2, 3, 4, b=5, z=6) → 2 + 20 + 500 + 1000 + 6 = 1528
    # f() → 0 + 0 + 100 + 0 = 100
    return f(2, 3, 4, b=5, z=6) + f()


managed_entry()
