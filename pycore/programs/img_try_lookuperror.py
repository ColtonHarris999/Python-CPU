"""except LookupError: catches raise KeyError and raise IndexError (Track 1)."""


def managed_entry():
    try:
        raise KeyError
    except LookupError:
        try:
            raise IndexError
        except LookupError:
            return 10


managed_entry()
