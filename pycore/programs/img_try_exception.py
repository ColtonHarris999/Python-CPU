"""except Exception: catches raise StopIteration (MRO, Track 1)."""


def managed_entry():
    try:
        raise StopIteration
    except Exception:
        return 7


managed_entry()
