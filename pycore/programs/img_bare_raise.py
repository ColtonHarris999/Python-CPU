"""A bare raise reuses the active exception and reaches an outer handler."""


def managed_entry():
    try:
        try:
            raise TypeError
        except TypeError:
            raise
    except TypeError:
        return 13
    return 0


managed_entry()
