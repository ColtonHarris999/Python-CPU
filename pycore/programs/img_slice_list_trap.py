"""Slicing a list is not implemented yet: PY_TRAP_TYPE (1).

Only string slicing landed in Plan 1 P6.1; list/tuple slicing needs an object
plus element-buffer allocation and an O(n) copy. Pinning the trap keeps the gap
visible rather than latent.

The list is built from variables so CPython emits BUILD_LIST rather than
BUILD_LIST 0 + LIST_EXTEND, which would need excore on this single-core target.
"""


def managed_entry():
    one = 1
    two = 2
    three = 3
    zero = 0
    xs = [one, two, three]
    return len(xs[zero:two])


managed_entry()
