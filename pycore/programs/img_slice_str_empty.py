"""Slicing an empty string, and zero-length slices of a non-empty one."""


def managed_entry():
    e = ""
    s = "ab"
    zero = 0
    two = 2
    five = 5
    total = 0
    if e[zero:zero] == "":
        total += 1
    if e[zero:five] == "":
        total += 10
    if s[zero:zero] == "":
        total += 100
    if s[two:five] == "":
        total += 1000
    return total


managed_entry()
