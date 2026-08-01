"""Delete attribute ``name`` from ``obj``.

Interim: ``del obj.__dict__[name]``. Missing key → MEM_FAULT trap
(no AttributeError object).
"""


def delattr(obj, name):
    d = obj.__dict__
    del d[name]
    return None
