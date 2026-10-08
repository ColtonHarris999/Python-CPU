"""List ``in`` rich equality (A12). Fixed with the container accelerator.

``1.0 in [1, 2]`` is True in CPython and False on the hart today.
"""


def managed_entry():
    if 1.0 in [1, 2]:
        return 1
    return 0


managed_entry()
