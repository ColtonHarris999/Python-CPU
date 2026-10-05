"""Phase 4 compiler cleanup after repeated caught SyntaxError failures.

# pycore-expect: 1
"""


def rejected_once():
    try:
        compile("import os", "<gc-bad>", "exec")
    except SyntaxError:
        # compile() refuses re-entry while _busy is set, so a second compile
        # succeeding shows the failed one cleared it. The program must not
        # name _PYC_G itself, or the image omits the idle-cleanup descriptor
        # this fixture exercises.
        return compile("1", "<gc-ok>", "eval") is not None
    return False


def managed_entry():
    first_free = 0
    free = 0
    i = 0
    while i < 32:
        if not rejected_once():
            return 0
        _bi_gc_collect()
        free = _bi_heap_free()
        if i == 0:
            first_free = free
        i = i + 1
    if free + 16384 < first_free:
        return 0
    return 1


managed_entry()
