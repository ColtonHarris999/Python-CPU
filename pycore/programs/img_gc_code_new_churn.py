"""_bi_code_new under heap pressure (G9 row 31 on both tops).

The code is blitted once. Each iteration builds the `_bi_code_new` field
list, then fills the current grant with dropped tuples until less than one
CODE_OBJECT fits, so the CODE_OBJECT allocation aborts, collects and
re-dispatches. Host `_bi_heap_free` is 0, so the fill is a no-op on CPython.
"""


def fill(room):
    # `_bi_heap_free` counts alignment pads no allocation can use, so the
    # chain can exhaust the usable runs first; that MemoryError is churn.
    try:
        drop = None
        while _bi_heap_free() >= room:
            drop = (drop, 1)
    except MemoryError:
        drop = None
    return drop is None


def managed_entry():
    # 128=RESUME, 94=LOAD_SMALL_INT, 35=RETURN_VALUE; stacksize 1.
    w0 = (0 << 8) | 128
    w1 = (7 << 8) | 94
    w2 = (0 << 8) | 35
    base = _bi_code_alloc(3)
    _bi_code_blit(base, [w0, w1, w2])
    total = 0
    n = 0
    while n < 40:
        fields = [base, (), (), 4294967296, (), (), {}, (), 0]
        fill(288)
        fn = _bi_code_new(fields)
        total = total + fn()
        n = n + 1
    return total


managed_entry()
