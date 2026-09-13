"""LONG_STR subscript: payload is a heap object, indexed via STRACC CHAR_AT."""


def managed_entry():
    s = "this is a long string!!"
    total = 0
    if s[0] == "t":
        total += 1
    if s[10] == "l":
        total += 10
    if s[22] == "!":
        total += 100
    return total


managed_entry()
