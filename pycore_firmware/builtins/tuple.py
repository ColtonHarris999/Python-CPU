"""Create a tuple.

``tuple()`` → empty tuple. Non-empty ``tuple(iterable)`` cannot emit a
dynamic BUILD_TUPLE without UNPACK_EX (``(*lst,)``) — traps via ``% 0``.
"""


def tuple(iterable=None):
    if iterable is None:
        return ()
    for _ in iterable:
        return 1 % 0
    return ()
