"""list.pop — native method table entry 1.

No-arg form deletes the last element (O(1) on pycore). Indexed pop uses
DELETE_SUBSCR; mid-list deletes need excore. Negative indices raise
IndexError (pycore does not wrap from the end).
"""


def list_pop(self, index=None):
    n = len(self)
    if n == 0:
        raise IndexError
    if index is None:
        i = n - 1
    else:
        i = index
        if i < 0:
            raise IndexError
        if i >= n:
            raise IndexError
    value = self[i]
    del self[i]
    return value
