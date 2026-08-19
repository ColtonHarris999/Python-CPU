"""Lone surrogates have no well-formed UTF-8 encoding: PY_TRAP_TYPE (trap 1).

Deviation: CPython allows chr(0xD800). PyCore stores strings as UTF-8 and every
string path (BI_LEN, FOR_ITER, s[i]) assumes well-formed input, so BI_CHR
rejects U+D800..U+DFFF instead.
"""


def managed_entry():
    return chr(55296)


managed_entry()
