"""Memory view over a bytes-like object.

No memoryview object kind / buffer protocol on pycore.
"""


def memoryview(obj):
    return 1 % 0
