"""list.extend — native method table entry 2.

Per-element LIST_EXTEND (`+= [x]`). Non-empty extend needs excore.
"""


def list_extend(self, iterable):
    for x in iterable:
        self += [x]
    return None
