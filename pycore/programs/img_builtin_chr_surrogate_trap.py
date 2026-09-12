"""Lone surrogates are valid code points under fixed-width kind 2.

Deviation retired: the UTF-8 SHORT path rejected U+D800..U+DFFF. STRACC stores
code units, so chr(0xD800) round-trips like CPython.
"""


def managed_entry():
    s = chr(55296)
    if ord(s) == 55296:
        return 1
    return 0


managed_entry()
