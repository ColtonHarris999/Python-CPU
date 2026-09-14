"""Code-RAM mark / release, and that the cursor starts at the write floor.

The floor is ``CODE_RAM_INIT_SLOT``: ``PYCORE_CODE_RAM_SLOT_BASE`` plus any
preloaded firmware-package slots (compiler_design.md step D). Nothing writes
code RAM here, so the cursor does not move on its own; this pins the
read/restore path.

# pycore-expect: 111
"""


def managed_entry():
    total = 0
    mark = _bi_code_mark()
    # Write floor sits in code RAM (>= PYCORE_CODE_RAM_SLOT_BASE).
    if mark >= 8192:
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
