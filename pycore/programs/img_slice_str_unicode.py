"""Slice bounds are CHARACTER indices, matching s[i] and `for c in s`.

"h" is 1 byte and "e-acute" is 2, so a byte-indexed implementation would cut
mid-character and produce invalid UTF-8 here.
"""


def managed_entry():
    s = "h\u00e9llo"
    zero = 0
    one = 1
    two = 2
    five = 5
    total = 0
    if s[zero:two] == "h\u00e9":
        total += 1
    if s[one:two] == "\u00e9":
        total += 10
    if s[one:five] == "\u00e9llo":
        total += 100
    if s[two:five] == "llo":
        total += 1000
    if s[zero:five] == "h\u00e9llo":
        total += 10000
    return total


managed_entry()
