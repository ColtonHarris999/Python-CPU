"""Out-of-range slice bounds clamp like CPython instead of trapping."""


def managed_entry():
    s = "abc"
    one = 1
    three = 3
    five = 5
    six = 6
    big = 99
    zero = 0
    total = 0
    if s[one:big] == "bc":
        total += 1
    if s[five:six] == "":
        total += 10
    if s[three:three] == "":
        total += 100
    if s[zero:big] == "abc":
        total += 1000
    if s[big:one] == "":
        total += 10000
    return total


managed_entry()
