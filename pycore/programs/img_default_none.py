"""All-defaults None fill: f() must install CONTROL|CTL_NONE (not wipe to UNINIT)."""


def f(a=None):
    if a is None:
        return 1
    return 0


def managed_entry():
    # Omit arg (defaults fill) + explicit None + override.
    return f() * 100 + f(None) * 10 + f(7)


managed_entry()
