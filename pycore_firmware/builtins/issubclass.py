"""True if ``cls`` is a subclass of ``classinfo``.

Single-class ``classinfo`` only; walks ``cls.__base__`` (depth ≤ 8).
Tuple-of-classes form deferred (see isinstance.md notes in builtins.md).
"""


def issubclass(cls, classinfo):
    cur = cls
    depth = 0
    while cur is not None:
        if cur is classinfo:
            result = True
            return result
        depth = depth + 1
        if depth > 8:
            cur = None
        else:
            cur = cur.__base__
    result = False
    return result
