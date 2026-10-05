"""GC steady state, compile (gc_plan.md G11): repeated small compile()/eval, retaining nothing.

Each iteration compiles and evaluates a fresh expression and collects
explicitly, so the plateau is measured at the same program point every
time (`reason=explicit` collections).
"""


def managed_entry():
    total = 0
    for i in range(40):
        code = compile(str(i) + " * 3 + 1", "<s>", "eval")
        total = total + eval(code)
        code = None
        _bi_gc_collect()
    return total


managed_entry()
