"""set.update — native method table entry 5.

Calls the native ``add`` method per element (LOAD_ATTR + CALL).
"""


def set_update(self, iterable):
    for x in iterable:
        self.add(x)
    return None
