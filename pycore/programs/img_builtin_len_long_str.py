"""BI_LEN on LONG_STR (UTF-8 byte length from descriptor)."""


def managed_entry():
    s = "this is a long string!!"
    return len(s)


managed_entry()
