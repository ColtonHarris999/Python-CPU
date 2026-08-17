"""SHORT_STR subscript s[i]: first, middle and last character."""


def managed_entry():
    s = "abcde"
    total = 0
    if s[0] == "a":
        total += 1
    if s[2] == "c":
        total += 10
    if s[4] == "e":
        total += 100
    if s[1] == "a":
        total += 1000
    return total


managed_entry()
