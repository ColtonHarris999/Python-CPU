"""Firmware next() raises catchable StopIteration when no default is given."""


def next(iterator, default=None):
    # Image-local firmware body: next is not in the production ROM registry.
    n = 0
    for _ in iterator:
        n = n + 1
        break
    if n == 0:
        if default is None:
            raise StopIteration
        return default
    value = iterator[0]
    del iterator[0]
    return value


def managed_entry():
    try:
        next([])
    except StopIteration:
        return 42
    return 0


managed_entry()
