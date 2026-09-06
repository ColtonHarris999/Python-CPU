"""STR * INT is not sequence-repeat; still PY_TRAP_TYPE (1).

``n`` is a local so CPython emits BINARY_OP rather than folding ``"ab" * 3``.
"""


def managed_entry():
    n = 3
    return "ab" * n


managed_entry()
