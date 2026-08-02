"""Return an iterator for an object.

One-arg form: materialize to a list (re-iterable). Sentinel form
(callable, sentinel) needs a custom iterator object + ``next`` — blocked.
"""


def iter(obj, sentinel=None):
    if sentinel is not None:
        raise 1
    out = []
    for x in obj:
        out += [x]
    return out
