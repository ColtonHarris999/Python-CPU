"""Get attribute ``name`` from ``obj``.

Uses ``obj.__dict__`` (LOAD_ATTR special → instance dict handle). Optional
default uses CONTAINS_OP then subscript — avoids AttributeError (RAISE
deferred). Does not walk the MRO.
"""


def getattr(obj, name, default=None):
    d = obj.__dict__
    if name in d:
        return d[name]
    return default
