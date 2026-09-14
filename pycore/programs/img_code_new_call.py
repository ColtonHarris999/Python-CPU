"""Blit RESUME / LOAD_SMALL_INT 7 / RETURN_VALUE, wrap in a code object, call it.

compiler_design.md step C: ``img_code_new_call`` golden is 7.
"""


def managed_entry():
    # opcode, arg packed as (arg << 8) | opcode. 128=RESUME, 94=LOAD_SMALL_INT,
    # 35=RETURN_VALUE. Metadata low-64 with stacksize=1 at bits [47:32].
    base = _bi_code_alloc(3)
    _bi_code_blit(base, [
        (0 << 8) | 128,
        (7 << 8) | 94,
        (0 << 8) | 35,
    ])
    fn = _bi_code_new([base, (), (), 4294967296, (), (), {}, (), 0])
    return fn()


managed_entry()
