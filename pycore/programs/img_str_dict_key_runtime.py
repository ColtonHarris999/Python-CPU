"""Runtime LONG concat equals an interned dict key (P5d three-tier eq).

``d[a + b]`` misses on main because LONG_STR compared by descriptor. STRACC
SA_CMP is the tier-3 payload compare that makes this correct.
"""


def managed_entry():
    prefix = "abcdefgh"
    suffix = "ijklmnop"
    key = prefix + suffix
    d = {"abcdefghijklmnop": 42}
    ok = d[key] == 42
    ok = ok and (key in d)
    hay = prefix + suffix + "XYZ"
    ok = ok and ("ijklmnop" in hay)
    ok = ok and ("abcdefghijklmnopXYZ" in hay)
    return 1 if ok else 0


managed_entry()
