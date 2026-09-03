"""CONVERT_VALUE (!s / !r) + FORMAT_SIMPLE + BUILD_STRING.

INT: f\"{x!s}:{x!r}\" with x=7 → \"7:7\" (repr of int has no quotes).
Length 3.
"""


def managed_entry():
    x = 7
    s = f"{x!s}:{x!r}"
    out = 0
    for _ in s:
        out += 1
    return out


managed_entry()
