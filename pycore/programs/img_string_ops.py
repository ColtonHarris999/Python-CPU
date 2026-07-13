# Short-string concat plus dict keyed by short and long string constants.

def tag_join(left, right):
    return left + right


def lookup_pair(short_key, long_key, short_val, long_val):
    d = {}
    d[short_key] = short_val
    d[long_key] = long_val
    return d[short_key] + d[long_key]


def managed_entry():
    joined = tag_join("ab", "cd")
    # "abcd" is still a short string; use it as a dict key.
    d = {}
    d[joined] = 11
    return d["abcd"] + lookup_pair("k", "longer string key!!", 4, 20)


managed_entry()
