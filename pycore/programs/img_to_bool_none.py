"""TO_BOOL on None is falsy (no TYPE trap)."""


def managed_entry():
    x = None
    if x:
        return 1
    return 0


managed_entry()
