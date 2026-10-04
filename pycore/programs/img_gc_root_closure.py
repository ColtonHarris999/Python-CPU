"""GC: a closure's cells survive a collection before COPY_FREE_VARS (gc_plan.md §6.4).

`mid` is created first, then the heap is filled. The only reference is popped
out of a dict immediately before CALL, so the FUNCTION is not in a local.
`mid` has a free variable (`k`) and its own cell (`y`), so its first
instruction is MAKE_CELL. Leftover < 128 B makes that allocation abort while
the closure tuple is held only by `cur_closure_r`.
"""

SRC = """\
def outer(k):
    def mid(x):
        y = x + k
        def inner():
            return y + k
        return inner()
    return mid
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    keep = ns["outer"](100)
    box = {}
    box["m"] = ns["outer"](7)
    ns = None
    junk = None
    while _bi_heap_free() > 48:
        junk = (junk, 12345678)
    junk = None
    r = box.pop("m")(5)
    _bi_gc_collect()
    return r * 1000 + keep(1)


managed_entry()
