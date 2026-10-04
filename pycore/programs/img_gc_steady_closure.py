"""GC steady state, closures (gc_plan.md G11): 1,000 closures with cells, called and dropped.

The factory comes from the on-device compiler (closures are not in the image
path); each iteration creates a cell and a FUNCTION object.
"""

SRC = """\
def make(k):
    def add(x):
        return x + k
    return add
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    make = ns["make"]
    ns = None
    total = 0
    for i in range(1000):
        f = make(i % 10)
        total = total + f(i) % 13
        if i % 80 == 0:
            _bi_gc_collect()
    return total


managed_entry()
