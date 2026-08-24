"""Raise and catch an already-constructed exception instance."""


def managed_entry():
    e = TypeError("x")
    try:
        raise e
    except TypeError:
        return 22


managed_entry()
