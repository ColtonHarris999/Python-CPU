"""Filter items where ``function`` is true — returns a list.

``function is None`` keeps truthy items (widened TO_BOOL). Deviation:
materializes results (no filter iterator / YIELD).
"""


def filter(function, iterable):
    out = []
    if function is None:
        for x in iterable:
            if x:
                out += [x]
        return out
    for x in iterable:
        if function(x):
            out += [x]
    return out
