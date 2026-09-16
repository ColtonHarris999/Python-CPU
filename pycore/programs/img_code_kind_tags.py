"""_bi_code_kind returns the raw 4-bit tag as INT (compiler_design.md §11.1).

INT=1, SHORT_STR=7, LONG_STR=8. Packed as 1*100 + 7*10 + 8 = 178.
The 16-byte literal is LONG_STR (SHORT_STR holds at most 15 UTF-8 bytes).
"""


def managed_entry():
    a = _bi_code_kind(5)
    b = _bi_code_kind("hi")
    c = _bi_code_kind("0123456789abcdef")
    return a * 100 + b * 10 + c


managed_entry()
