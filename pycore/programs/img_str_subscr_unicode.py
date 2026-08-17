"""s[i] indexes CHARACTERS, not bytes, matching `for c in s` and CPython.

"h" is 1 byte and "e-acute" is 2, so a byte-indexed implementation would
return a partial continuation byte for s[2] instead of "l".
"""


def managed_entry():
    s = "héllo"
    total = 0
    if s[0] == "h":
        total += 1
    if s[1] == "é":
        total += 10
    if s[2] == "l":
        total += 100
    if s[4] == "o":
        total += 1000
    return total


managed_entry()
