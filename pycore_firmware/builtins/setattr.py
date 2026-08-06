"""Set attribute ``name`` on ``obj`` to ``value``.

Writes ``obj.__dict__[name] = value`` (STORE_SUBSCR). STORE_ATTR needs a
compile-time co_names index, not a runtime string.
"""


def setattr(obj, name, value):
    d = obj.__dict__
    d[name] = value
    return None
