# Caller locals must survive a callee deep enough to spill the caller's window.


def inner(n):
    if n <= 0:
        return 0
    return inner(n - 1) + 1


def outer():
    x = 42
    y = 17
    z = inner(120)
    return x + y + z


def managed_entry():
    return outer()


managed_entry()
