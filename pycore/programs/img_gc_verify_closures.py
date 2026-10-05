"""GC: closures, cells, and function objects (gc_plan.md Phase 0).

Closures only come from the on-device compiler, so the source is compiled on
PyCore. A counter closure keeps its cell alive through the FUNCTION object's
closure tuple; discarded closures and their cells become garbage, as does
the compiler's working set.
"""

SRC = """\
def make_counter(start):
    count = [start]
    def inc(step):
        count[0] = count[0] + step
        return count[0]
    return inc

def adder(n):
    return lambda x: x + n
"""


def managed_entry():
    ns = {}
    exec(compile(SRC, "<s>", "exec"), ns)
    c = ns["make_counter"](5)
    f = ns["adder"](7)
    mk = ns["make_counter"]
    garbage = [mk(0), mk(1), mk(2), mk(3), mk(4)]
    garbage = None
    _bi_gc_collect()
    c(3)
    total = c(4) + f(1)
    _bi_gc_collect()
    return total + c(0)


managed_entry()
