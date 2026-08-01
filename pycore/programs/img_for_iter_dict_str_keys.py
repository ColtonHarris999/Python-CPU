"""DICT iteration preserves SHORT_STR/LONG_STR insertion order."""


def managed_entry():
    d = {}
    d["a"] = 1
    d["abcdefghijklmnopqrst"] = 2
    result = 0
    for key in d:
        result = d[key]
    return result


managed_entry()
