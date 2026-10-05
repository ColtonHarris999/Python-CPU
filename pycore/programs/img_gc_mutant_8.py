"""G10 mutant 8: skip cur_closure_r (gc_plan.md §10.2).

`mid` is created first (heap still empty), then the heap is filled. The only
reference is popped out of a dict immediately before CALL, so the FUNCTION is
not in a local. `mid`'s first instruction is MAKE_CELL; leftover < 128 B
makes that allocation abort while the closure tuple is held only by
`cur_closure_r`. Skipping that root sweeps the cell; LOAD_DEREF disagrees
with CPython, and G4's stash check disagrees with the testbench root set.
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
