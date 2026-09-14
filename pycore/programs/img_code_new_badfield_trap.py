"""_bi_code_new with a wrong field tag traps TYPE (1).

Nine entries, but field 1 (co_consts) is an INT instead of a TUPLE.
"""


def managed_entry():
    w0 = (0 << 8) | 128
    base = _bi_code_alloc(1)
    _bi_code_blit(base, [w0])
    _bi_code_new([base, 0, (), 0, (), (), {}, (), 0])
    return 0


managed_entry()
