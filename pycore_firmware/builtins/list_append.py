"""list.append — native method table entry 0.

Uses LIST_EXTEND (`self += [value]`) so grow goes through the existing
excore trap. Do not call `self.append` here (that would recurse).
"""


def list_append(self, value):
    self += [value]
    return None
