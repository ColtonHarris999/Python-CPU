"""INT keys -1 and -2 share CPython hash (-2) but remain distinct keys.

Same-tag probe continues past unequal match; both entries stay present.
"""


def managed_entry():
    d = {}
    d[-1] = 10
    d[-2] = 20
    return d[-1] + d[-2]


managed_entry()
