"""Heap mark / release: allocate, release to the mark, reallocate (Plan 1 P8).

Reallocating after a release must hand back the same addresses, which is what
makes the mechanism useful for repeated compilation in Plan 2.

Not GC: any handle allocated after the mark is dangling once released, so this
program drops its reference before releasing.

CPython has no bump cursor to expose, so the expected value is stated directly.
# pycore-expect: 11111
"""


def managed_entry():
    mark = _bi_heap_mark()
    a = [1, 2]
    after_a = _bi_heap_mark()
    total = 0
    if after_a > mark:
        total += 1
    if len(a) == 2:
        total += 10
    # Drop the reference, then rewind the cursor.
    a = None
    _bi_heap_release(mark)
    if _bi_heap_mark() == mark:
        total += 100
    # A fresh allocation of the same shape lands at the same address.
    b = [3, 4]
    if _bi_heap_mark() == after_a:
        total += 1000
    if len(b) == 2:
        total += 10000
    return total


managed_entry()
