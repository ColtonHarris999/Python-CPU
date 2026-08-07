"""True if ``obj`` has attribute ``name``.

Probes ``obj.__dict__`` with CONTAINS_OP (instances only). No MRO /
class-attr walk (would need LOAD_ATTR by runtime string).
"""


def hasattr(obj, name):
    d = obj.__dict__
    if name in d:
        result = True
        return result
    result = False
    return result
