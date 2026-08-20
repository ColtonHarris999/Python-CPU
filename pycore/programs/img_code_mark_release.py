"""Code-RAM mark / release, and that the cursor starts at the region base.

Nothing writes code RAM yet, so the cursor does not move on its own; this pins
the read/restore path and the region base so P2's loader and Plan 2's emitter
inherit a tested primitive.

# pycore-expect: 111
"""


def managed_entry():
    total = 0
    mark = _bi_code_mark()
    # 0x2000 == PYCORE_CODE_RAM_SLOT_BASE.
    if mark == 8192:
        total += 1
    _bi_code_release(mark)
    if _bi_code_mark() == mark:
        total += 10
    # Releasing to the current cursor is a no-op, not an error.
    _bi_code_release(_bi_code_mark())
    if _bi_code_mark() == mark:
        total += 100
    return total


managed_entry()
