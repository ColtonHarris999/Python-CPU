"""except (StopIteration, ValueError): tuple handler (Track 1)."""


def managed_entry():
    try:
        raise ValueError
    except (StopIteration, ValueError):
        return 9


managed_entry()
