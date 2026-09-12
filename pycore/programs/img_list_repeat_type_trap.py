"""STR * INT is sequence-repeat on STRACC: "ab" * 3 == "ababab".

``n`` is a local so CPython emits BINARY_OP rather than folding ``"ab" * 3``.
The old ALU TYPE-trapped; the accelerator matches CPython.
"""


def managed_entry():
    n = 3
    return len("ab" * n)


managed_entry()
