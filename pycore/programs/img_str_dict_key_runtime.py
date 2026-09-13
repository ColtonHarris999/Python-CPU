"""Runtime LONG concat equals an interned dict key (P5d three-tier eq).

``d[a + b]`` and ``key in d`` miss on descriptor compare. STRACC SA_CMP is
the tier-3 payload compare that makes this correct.

``del d[key]`` and ``d.pop(key)`` also walk the insertion-order buffer
with the same equality, so they need a second SA_CMP after the table
probe. Without it the scan never matches and the core MEM_FAULTs.
"""


def managed_entry():
    prefix = "abcdefgh"
    suffix = "ijklmnop"
    key = prefix + suffix
    d = {"abcdefghijklmnop": 42, "otherlongstring!!": 7}
    ok = d[key] == 42
    ok = ok and (key in d)
    hay = prefix + suffix + "XYZ"
    ok = ok and ("ijklmnop" in hay)
    ok = ok and ("abcdefghijklmnopXYZ" in hay)
    del d[key]
    ok = ok and (key not in d)
    ok = ok and (len(d) == 1)
    ok = ok and d["otherlongstring!!"] == 7
    k2 = "other" + "longstring!!"
    v = d.pop(k2)
    ok = ok and v == 7
    ok = ok and (k2 not in d)
    ok = ok and (len(d) == 0)
    return 1 if ok else 0


managed_entry()
