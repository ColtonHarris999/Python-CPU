"""G13 benchmark: a 10,000-deep linked chain (gc_plan.md G13 P7: mark-stack depth and spill)."""


def managed_entry():
    chain = None
    for i in range(10000):
        chain = (chain,)
    _bi_gc_collect()
    _bi_gc_collect()
    depth = 0
    while chain is not None:
        chain = chain[0]
        depth = depth + 1
    return depth


managed_entry()
