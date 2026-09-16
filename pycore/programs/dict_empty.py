"""Empty dict then insert; return d[1]. Expected: INT 2."""


def managed_entry():
    d = {}
    d[1] = 2
    return d[1]


managed_entry()
