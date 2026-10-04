"""Phase 4 compiler-arena lifetime and code-RAM growth fixture.

Compile the same closure-producing expression 64 times without region-mark
subtraction.  Four functions from widely separated iterations stay live
across later collections; every other compiler result is dropped before an
explicit collection.  Heap free space must settle while code RAM advances by
the same amount per compile.

# pycore-expect: 1
"""


SRC = """#xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
(lambda x: lambda: x)(7)"""


def managed_entry():
    saved0 = None
    saved1 = None
    saved2 = None
    saved3 = None
    first_free = 0
    before_code = _bi_code_mark()
    one_code = before_code
    i = 0
    while i < 64:
        code = compile(SRC, "<gc-loop>", "eval")
        fn = eval(code)
        if i == 0:
            saved0 = fn
        elif i == 21:
            saved1 = fn
        elif i == 42:
            saved2 = fn
        elif i == 63:
            saved3 = fn
        code = None
        fn = None
        # Ten explicit collections: after iterations 0, 8, ..., 56 and 63,
        # plus the final collection after the retained closures are dropped.
        if i % 8 == 0 or i == 63:
            _bi_gc_collect()
            free = _bi_heap_free()
            if first_free == 0:
                first_free = free
        if i == 0:
            one_code = _bi_code_mark()
        i = i + 1

    after_code = _bi_code_mark()
    if one_code != before_code:
        if after_code - before_code != 64 * (one_code - before_code):
            return 0
    if free + 16384 < first_free:
        return 0
    if saved0() != 7:
        return 0
    if saved1() != 7:
        return 0
    if saved2() != 7:
        return 0
    if saved3() != 7:
        return 0
    saved0 = None
    saved1 = None
    saved2 = None
    saved3 = None
    _bi_gc_collect()
    return 1


managed_entry()
