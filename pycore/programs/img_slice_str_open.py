"""Open-ended slices: CPython passes None for the omitted bound.

Variable omitted bounds emit BINARY_SLICE with None. All-literal `s[:]` is
covered by img_slice_str_const (slice-const rewrite).
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
