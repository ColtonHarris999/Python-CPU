"""Blit, call, patch the same slots, call again — catches stale L1I / line buffer.

compiler_design.md step C / R-3 / R-6. First call returns 1 (fills fetch + L1I);
patching LOAD_SMALL_INT to 7 and calling again must return 7, not the cached 1.
Golden is 17 (1 * 10 + 7).
"""


def managed_entry():
    base = _bi_code_alloc(3)
    _bi_code_blit(base, [
        (0 << 8) | 128,
        (1 << 8) | 94,
        (0 << 8) | 35,
    ])
    fn = _bi_code_new([base, (), (), 4294967296, (), (), {}, (), 0])
    first = fn()
    _bi_code_patch(base + 1, (7 << 8) | 94)
    second = fn()
    return first * 10 + second


managed_entry()
