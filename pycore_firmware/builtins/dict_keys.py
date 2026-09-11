"""dict.keys — native method table entry 11.

Materializes a list (no dict-view objects).
"""


def dict_keys(self):
    out = []
    for k in self:
        out += [k]
    return out
