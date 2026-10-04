"""G8: replace() with a longer new string must not drop a haystack char.

`str.replace("-", "+-")` on a 27-char haystack writes a 32-byte LONG_STR.
The 17th output char ('0') sits on a 16-byte dest-word boundary. STRACC
`consume_unit` flushes the dirty word there and used to discard the unit
while still advancing the haystack cursor, so the '0' vanished (ords 2719
instead of 2767) even with GC_EN=0.
"""


def managed_entry():
    s = "string-number-" + str(0) + "-with-a-tail"
    r = s.replace("-", "+-")
    n = 0
    for ch in r:
        n = n + ord(ch)
    return n + len(r)


managed_entry()
