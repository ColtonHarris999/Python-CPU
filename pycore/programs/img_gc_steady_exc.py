"""GC steady state, exceptions (gc_plan.md G11): raise with args, catch, drop."""


def fail(i):
    raise ValueError((i, "steady-exception-payload-" + str(i % 5)))


def managed_entry():
    total = 0
    for i in range(1000):
        try:
            fail(i)
        except ValueError as e:
            total = total + e.args[0][0] % 7 + len(e.args[0][1])
        try:
            raise KeyError
        except KeyError:
            total = total + 1
    return total


managed_entry()
