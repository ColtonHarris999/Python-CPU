"""SHORT_STR keys: store, lookup, contains, delete (same-tag)."""


def managed_entry():
    d = {}
    d["a"] = 1
    d["b"] = 2
    d["c"] = 3
    n = d["a"] + d["b"] + d["c"]
    del d["b"]
    if "b" not in d:
        if "a" in d:
            return n + 10
    return 0


managed_entry()
