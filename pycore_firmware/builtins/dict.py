"""Create a dict from an iterable of ``(key, value)`` pairs.

No kwargs (CALL_KW deferred). No dict-comprehension MAP_ADD.
Copying a mapping: iterate keys and ``out[k] = mapping[k]``.
"""


def dict(iterable=None):
    out = {}
    if iterable is None:
        return out
    for item in iterable:
        k, v = item
        out[k] = v
    return out
