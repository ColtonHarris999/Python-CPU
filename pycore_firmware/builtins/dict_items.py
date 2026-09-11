"""dict.items — native method table entry 12.

Materializes a list of ``(key, value)`` tuples.
"""


def dict_items(self):
    out = []
    for k in self:
        out += [(k, self[k])]
    return out
