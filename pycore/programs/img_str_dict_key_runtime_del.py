"""del / pop on a runtime-built LONG_STR key equal to an interned key (P5d).

The table probe matches via tier-3 SA_CMP, but the insertion-order-buffer scan
in CONT_DELETE_DICT compared with bare tier-1 (address) equality, never
matched a distinct-address key, and faulted at the end of the order buffer.
This exercises both del d[k] and d.pop(k) with such a key.
"""


def managed_entry():
    a = "abcdefgh"
    b = "ijklmnop"
    key = a + b
    d = {"abcdefghijklmnop": 42, "other": 7, "third": 9}
    del d[key]
    ok = len(d) == 2
    ok = ok and ("abcdefghijklmnop" not in d)
    ok = ok and (d["other"] == 7)
    # pop with a second runtime-built key equal to a remaining interned key.
    d2 = {"prefixsuffixzz": 1, "keep": 2}
    k2 = "prefixsuffix" + "zz"
    v = d2.pop(k2)
    ok = ok and (v == 1)
    ok = ok and (len(d2) == 1)
    return 1 if ok else 0


managed_entry()
