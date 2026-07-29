"""Rich equality on set: add 1, check True in s (pycore, no excore)."""


def managed_entry():
    a = 1
    s = {a}
    if True in s:
        return 1
    return 0


managed_entry()
