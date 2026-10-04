"""G10 mutant 40 (B14): a release below the heap base faults after a GC.

`_bi_heap_release` treats a mark from an older epoch as superseded by a
collection and ignores it. INT 0 has epoch 0 but lies below the heap base,
so it is never a mark: after a collection it must still trap 7
(PY_TRAP_MEM_FAULT), as `img_heap_release_below_base_trap` does without one.
"""


def managed_entry():
    _bi_gc_collect()
    _bi_heap_release(0)
    return 0


managed_entry()
