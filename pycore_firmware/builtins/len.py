"""Number of items in an iterable (count via FOR_ITER).

Deviation: O(n) iteration count instead of O(1) container headers /
__len__. Native BI_LEN remains the O(1) on-core path.
"""


def len(obj):
    n = 0
    for _ in obj:
        n = n + 1
    return n
