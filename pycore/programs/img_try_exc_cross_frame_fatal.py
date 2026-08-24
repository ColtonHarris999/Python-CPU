"""An exception raised in a callee reaches the caller's matching handler."""


def fail():
    raise ValueError


def managed_entry():
    try:
        fail()
    except ValueError:
        return 1
    return 0


managed_entry()
