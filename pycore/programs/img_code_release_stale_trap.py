"""Code-RAM release above the cursor must fault: PY_TRAP_MEM_FAULT (7)."""


def managed_entry():
    mark = _bi_code_mark()
    _bi_code_release(mark + 8)
    return 0


managed_entry()
