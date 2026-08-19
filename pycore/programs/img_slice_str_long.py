"""Slices crossing the SHORT_STR/LONG_STR boundary in both directions.

The subject is a LONG_STR (>15 bytes). A slice of <= 15 bytes must come back as
an inline SHORT_STR (so `==` against a literal works); longer ones are written
to string_mem as a LONG_STR, whose equality is *descriptor* equality
(bytecode_support.md deviation 4) -- so those are checked by length and by
sampling characters rather than by comparing whole strings. Content-based
long-string equality is Plan 1 P6.4 and is not implemented yet.

Slice lengths of exactly 15 and 16 bytes pin the tag boundary.
"""


def managed_entry():
    s = "abcdefghijklmnopqrstuvwxyz"
    zero = 0
    three = 3
    ten = 10
    fifteen = 15
    sixteen = 16
    n = 26
    total = 0
    # <= 15 bytes: inline SHORT_STR, so direct comparison is valid.
    if s[zero:three] == "abc":
        total += 1
    if s[zero:fifteen] == "abcdefghijklmno":
        total += 10
    # 16 bytes: LONG_STR result. Check length and endpoints instead.
    a = s[zero:sixteen]
    if len(a) == 16:
        total += 100
    if a[zero] == "a":
        total += 1000
    if a[fifteen] == "p":
        total += 10000
    # Interior long slice.
    b = s[ten:n]
    if len(b) == 16:
        total += 100000
    if b[zero] == "k":
        total += 1000000
    # Full-length copy.
    c = s[zero:n]
    if len(c) == 26:
        total += 10000000
    return total


managed_entry()
