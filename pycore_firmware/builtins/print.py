"""Print objects to the console.

Public ``print`` is a ROM CODE_OBJECT with full ``*args`` / ``sep=`` /
``end=`` support (needs CO_VARARGS + CALL_KW). Each piece is handed to
native ``_bi_print`` (OBK_BUILTIN / BI_PRINT → CONSOLE_TX).

``_bi_print`` accepts one INT / BOOL / None / SHORT_STR. LONG_STR is
Phase 2 on the native sink; this body never concatenates a full line so
long user strings can later stream with ``for c in s: _bi_print(c)``.
"""


def print(*args, sep=" ", end="\n"):
    n = len(args)
    i = 0
    while i < n:
        if i > 0:
            _bi_print(sep)
        _bi_print(args[i])
        i = i + 1
    _bi_print(end)
    return None
