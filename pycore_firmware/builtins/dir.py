"""List valid attribute names.

Needs namespace / MRO keys materialization and sorted names. Partial
interim: keys of ``obj.__dict__`` only.
"""


def dir(obj=None):
    if obj is None:
        return 1 % 0
    out = []
    d = obj.__dict__
    for k in d:
        out += [k]
    return out
