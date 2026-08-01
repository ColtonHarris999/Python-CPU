"""Return True if ``obj`` appears callable.

Interim heuristic: CODE_OBJECT handles are not distinguishable in pure
Python. Treat presence of ``__call__`` in ``__dict__`` / type dict as
callable; also accept objects that define no __dict__ as unknown→False.
"""


def callable(obj):
    # Featureless check: look for __call__ on the instance/type dicts.
    d = obj.__dict__
    if "__call__" in d:
        result = True
        return result
    cls = obj.__class__
    td = cls.__dict__
    if "__call__" in td:
        result = True
        return result
    result = False
    return result
