"""All-literal string slices: CPython folds these to slice + NB_SUBSCR.

The image compiler rewrites that form to BINARY_SLICE so `s[1:]` / `s[:]`
boot without slice objects. Variable-bound coverage remains in img_slice_str*.
"""


def managed_entry():
    s = "abcdef"
    total = 0
    if s[1:] == "bcdef":
        total += 1
    if s[2:] == "cdef":
        total += 10
    if s[:3] == "abc":
        total += 100
    if s[1:4] == "bcd":
        total += 1000
    if s[:] == "abcdef":
        total += 10000
    return total


managed_entry()
