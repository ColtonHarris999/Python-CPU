"""Create a tuple.

``tuple()`` → empty tuple. Non-empty ``tuple(iterable)`` materializes a
list then uses CPython 3.14 ``(*lst,)`` → ``CALL_INTRINSIC_1`` /
``INTRINSIC_LIST_TO_TUPLE``.
"""


def tuple(iterable=None):
    if iterable is None:
        return ()
    out = []
    for x in iterable:
        out += [x]
    return (*out,)
