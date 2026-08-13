"""CALL_FUNCTION_EX with **kwargs packing on the callee."""


def f(a=0, **k):
    return a + len(k) + (0 if len(k) == 0 else k["z"])


def managed_entry():
    d = {"z": 9}
    x = f(*(1,), **d)
    y = f(*(), **{})
    return x + y


managed_entry()
