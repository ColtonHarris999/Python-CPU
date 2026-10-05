"""_bi_code_new (G9 row 31): compile a tiny eval expression and drop it.

No eval, no later exception (B11). 200 compiles of a one-byte source so the
256 B CODE_OBJECT is a large fraction of each iteration's heap traffic.
"""


def managed_entry():
    total = 0
    keep = None
    for i in range(8):
        code = compile("1", "<s>", "eval")
        keep = code
        total = total + 1
    return total + (0 if keep is None else 1)


managed_entry()
