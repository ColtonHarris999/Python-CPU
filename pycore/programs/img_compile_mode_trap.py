"""A5: compile() rejects ``single`` and nonzero flags (compiler_design.md I).

Each check lives in its own function: two ``try``/``except`` around callee
raises in one frame currently traps (illegal opcode) on the second catch.
``catch_single`` + ``catch_flags`` → 3 when both raise ``ValueError``.
"""


def catch_single():
    try:
        compile("1", "<s>", "single")
        return 0
    except ValueError:
        return 1


def catch_flags():
    try:
        compile("1", "<s>", "eval", 1)
        return 0
    except ValueError:
        return 2


def managed_entry():
    return catch_single() + catch_flags()


managed_entry()
