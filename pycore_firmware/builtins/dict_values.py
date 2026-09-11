"""dict.values — native method table entry 15.

Materializes a list (no dict-view objects).
"""


def dict_values(self):
    out = []
    for k in self:
        out += [self[k]]
    return out
