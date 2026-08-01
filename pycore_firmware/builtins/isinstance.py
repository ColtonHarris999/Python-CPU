"""True if ``obj`` is an instance of ``classinfo``.

``classinfo`` must be a single class object. Walks ``obj.__class__``
via ``__base__`` (depth ≤ 8). Tuple/list-of-types form deferred (cannot
branch on type tag in pure Python without trapping).
"""


def isinstance(obj, classinfo):
    cls = obj.__class__
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
