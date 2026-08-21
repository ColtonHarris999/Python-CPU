"""Bind an exception with ``except T as e`` and complete handler cleanup."""


def managed_entry():
    result = 0
    try:
        raise TypeError
    except TypeError as exc:
        result = 7
    return result


managed_entry()
