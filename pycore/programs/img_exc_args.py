"""Read OBK_EXCEPTION.args via LOAD_ATTR. Expected: 2."""


def managed_entry():
    try:
        raise TypeError("x")
    except TypeError as e:
        a = e.args
        n = len(a)
        if a[0] == "x":
            n = n + 1
        return n
    return 0


managed_entry()
