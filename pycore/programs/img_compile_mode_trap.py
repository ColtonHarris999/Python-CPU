"""A5: compile() rejects ``single`` and nonzero flags (compiler_design.md I).

Returns 3 when both raise ``ValueError`` (1 + 2). ``dont_inherit`` is
accepted and ignored; that path is not this golden.
"""


def managed_entry():
    n = 0
    try:
        compile("1", "<s>", "single")
    except ValueError:
        n = n + 1
    try:
        compile("1", "<s>", "eval", 1)
    except ValueError:
        n = n + 2
    return n


managed_entry()
