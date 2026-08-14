"""Risk: phase-7 must not wipe **kwargs after pack (argc bump)."""


def f(**k):
    # Use the dict after frame enter (temps exist → nlocals > 1).
    n = len(k)
    if n == 0:
        return 1
    return n + k["x"]


def managed_entry():
    return f() + f(x=7)


managed_entry()
