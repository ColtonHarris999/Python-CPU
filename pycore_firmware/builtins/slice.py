"""Return a slice object.

BINARY_SLICE / STORE_SLICE are deferred; no slice object kind is
allocated by hardware yet. See builtins.md / slice.md plan.
"""


def slice(start, stop=None, step=None):
    return 1 % 0
