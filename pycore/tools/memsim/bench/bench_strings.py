# Long-string workload for memsim / RTL comparison (P9).
#
# Payloads are >=16 characters so they are LONG_STR heap objects (kind-1).
# STR * INT is outside the supported subset; the loop concatenates instead.
# Native methods used: str.find. Indexing, slicing, `in`, len, and == stay
# on the STRACC / handle paths.

def managed_entry():
    a = "abcdefghijklmnop"
    b = "qrstuvwxyz012345"
    s = a
    i = 0
    while i < 8:
        s = s + b
        i = i + 1
    n = len(s)
    if "xyz01" in s:
        n = n + 1
    if s[0] == "a":
        n = n + 10
    t = s[4:40]
    n = n + len(t)
    i = 0
    while i < 16:
        ch = s[i]
        if ch == "a":
            n = n + 1
        i = i + 1
    found = s.find("012")
    n = n + found
    extra = a + b
    if extra == "abcdefghijklmnopqrstuvwxyz012345":
        n = n + 100
    return n


managed_entry()
