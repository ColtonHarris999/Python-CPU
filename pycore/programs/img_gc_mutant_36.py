"""G10 mutant 36: OOM loop guard and empty-list MEM_FAULT disabled (gc_plan.md §10.2).

A live chain larger than the shrunk heap must MEM_FAULT. The empty-list check
is what actually stops the allocator after a fruitless collection; skipping
it (and the loop guard) leaves the core in S_GC_ALLOC forever.
"""


def managed_entry():
    chain = None
    n = 0
    while n < 2000:
        chain = (chain, "live-link")
        n = n + 1
    return n


managed_entry()
