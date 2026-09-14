"""Blit RESUME / LOAD_SMALL_INT 7 / RETURN_VALUE, wrap in a code object, call it.

compiler_design.md step C: ``img_code_new_call`` golden is 7.

Word lists are built from locals so CPython 3.14 emits BUILD_LIST, not
LIST_EXTEND of a constant tuple (LIST_EXTEND is excore-only on the
single-core image binary).
"""


def managed_entry():
    # opcode, arg packed as (arg << 8) | opcode. 128=RESUME, 94=LOAD_SMALL_INT,
    # 35=RETURN_VALUE. Metadata low-64 with stacksize=1 at bits [47:32].
    w0 = (0 << 8) | 128
    w1 = (7 << 8) | 94
    w2 = (0 << 8) | 35
    base = _bi_code_alloc(3)
    _bi_code_blit(base, [w0, w1, w2])
    fn = _bi_code_new([base, (), (), 4294967296, (), (), {}, (), 0])
    return fn()


managed_entry()
