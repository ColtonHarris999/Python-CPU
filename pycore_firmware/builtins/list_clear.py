"""list.clear — native method table entry 3.

Deletes from the end so every step is the O(1) last-element path.
"""


def list_clear(self):
    n = len(self)
    while n > 0:
        del self[n - 1]
        n = n - 1
    return None
