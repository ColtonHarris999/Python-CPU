"""Return ``obj.__dict__``, or empty dict with no argument.

``locals()`` fallback needs frame introspection (blocked).
"""


def vars(obj=None):
    if obj is None:
        return {}
    return obj.__dict__
