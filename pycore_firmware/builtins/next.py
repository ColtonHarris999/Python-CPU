"""Retrieve the next item from an iterator.

No general iterator protocol. List-queue interim: pop ``iterator[0]``.
Exhaustion with default returns default; without default raises (fatal).
"""


def next(iterator, default=None):
    n = 0
    for _ in iterator:
        n = n + 1
        break
    if n == 0:
        if default is None:
            raise 1
        return default
    value = iterator[0]
    del iterator[0]
    return value
