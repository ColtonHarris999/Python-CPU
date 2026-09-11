"""dict.update — native method table entry 13.

Mapping form only: ``for k in other: self[k] = other[k]``.
"""


def dict_update(self, other):
    for k in other:
        self[k] = other[k]
    return None
