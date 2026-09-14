"""Blit, call, patch the same slots, call again — catches stale L1I / line buffer.

compiler_design.md step C / R-3 / R-6. First call returns 1 (fills fetch + L1I);
patching LOAD_SMALL_INT to 7 and calling again must return 7, not the cached 1.
Golden is 17 (1 * 10 + 7).

Word lists are built from locals so CPython 3.14 emits BUILD_LIST, not
LIST_EXTEND of a constant tuple.
"""


def managed_entry():
    w0 = (0 << 8) | 128
    w1 = (1 << 8) | 94
    w2 = (0 << 8) | 35
    base = _bi_code_alloc(3)
    _bi_code_blit(base, [w0, w1, w2])
    fn = _bi_code_new([base, (), (), 4294967296, (), (), {}, (), 0])
    first = fn()
    patched = (7 << 8) | 94
    _bi_code_patch(base + 1, patched)
    second = fn()
    return first * 10 + second


managed_entry()
