"""CONVERT_VALUE !r on SHORT_STR wraps in single quotes.

f\"{s!r}\" with s=\"ab\" → \"'ab'\" length 4.
"""


def managed_entry():
    s = "ab"
    r = f"{s!r}"
    out = 0
    for _ in r:
        out += 1
    return out


managed_entry()
