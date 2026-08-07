"""Create a dict from an iterable of ``(key, value)`` pairs.

No kwargs constructor (``dict(a=1)``). Dict-display comprehensions use
MAP_ADD on the caller side; this builtin builds via STORE_SUBSCR.
"""


def dict(iterable=None):
    out = {}
    if iterable is None:
        return out
    for item in iterable:
        k, v = item
        out[k] = v
    return out
