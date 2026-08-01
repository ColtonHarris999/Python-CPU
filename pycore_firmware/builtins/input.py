"""Read a line from stdin.

No stdin device / MMIO line discipline on pycore yet.
"""


def input(prompt=None):
    return 1 % 0
