"""Open-ended slices: CPython passes None for the omitted bound.

`s[:]` is not covered here because CPython folds it to a constant
`slice(None, None, None)` plus NB_SUBSCR, which needs slice objects rather than
BINARY_SLICE.
"""


def managed_entry():
    s = "abcdef"
    zero = 0
    two = 2
    six = 6
    total = 0
    if s[two:] == "cdef":
        total += 1
    if s[:two] == "ab":
        total += 10
    if s[six:] == "":
        total += 1000
    if s[zero:] == "abcdef":
        total += 10000
    return total


managed_entry()
