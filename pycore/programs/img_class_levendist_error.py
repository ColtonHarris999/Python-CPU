"""T10: OSS-shaped ValueError subclass (levendist.LevenDistError)."""


class LevenDistError(ValueError):
    """Raised on invalid input."""


def managed_entry():
    try:
        raise LevenDistError
    except ValueError:
        return 12


managed_entry()
