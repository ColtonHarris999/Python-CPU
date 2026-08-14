"""except Exception: catches raise TypeError as a bare type (Track 1 + T5-A)."""


def managed_entry():
    try:
        raise TypeError
    except Exception:
        return 8


managed_entry()
