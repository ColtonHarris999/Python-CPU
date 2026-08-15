"""Nested try/except StopIteration exercises the dmem exc-info stack."""


def managed_entry():
    try:
        try:
            raise StopIteration
        except StopIteration:
            raise StopIteration
    except StopIteration:
        return 11


managed_entry()
