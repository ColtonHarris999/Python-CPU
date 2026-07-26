"""Short-string set elements + contains."""


def managed_entry():
    a = "ab"
    b = "cd"
    s = {a, b}
    n = 0
    if "ab" in s:
        n = n + 1
    if "cd" in s:
        n = n + 2
    if "ef" not in s:
        n = n + 4
    return n


managed_entry()
