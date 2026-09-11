"""T10: except MyError identity-matches the folded user subclass."""


class MyError(Exception):
    pass


def managed_entry():
    try:
        raise MyError
    except MyError:
        return 11


managed_entry()
