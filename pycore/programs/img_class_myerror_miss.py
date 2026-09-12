"""T10: except TypeError does not catch MyError(Exception)."""


class MyError(Exception):
    pass


def managed_entry():
    try:
        raise MyError
    except TypeError:
        return 0


managed_entry()
