"""Build a one-entry dict {key: value} and return d[key].

Locals force BUILD_MAP (not BUILD_CONST_KEY_MAP). Expected: INT 42.
"""


def managed_entry():
    k = 7
    v = 42
    d = {k: v}
    return d[k]


managed_entry()
