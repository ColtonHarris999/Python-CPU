"""LONG_STR literals iterate once per UTF-8 code point."""


def managed_entry():
    total = 0
    for c in "this is a long string!!":
        total += 1
    return total


managed_entry()
