"""T10: fold class MyError(Exception); raise + except Exception (MRO)."""


class MyError(Exception):
    pass


def managed_entry():
    try:
        raise MyError("x")
    except Exception:
        return 10


managed_entry()
