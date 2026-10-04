"""GC: objects reachable only from the active exception survive (gc_plan.md §6.4).

The exception's argument holds the only reference to a fresh list; collections
run while the exception is being handled (active exception register and
exception-stack node) and after it was bound to a name.
"""


def fail(n):
    payload = [n, "exception-owned-payload-" + str(n)]
    raise ValueError((payload, n))


def managed_entry():
    total = 0
    for n in range(3):
        try:
            fail(n)
        except ValueError as e:
            _bi_gc_collect()
            junk = [n, n, n]
            junk = None
            _bi_gc_collect()
            total = total + len(e.args[0][0][1]) + e.args[0][1]
    try:
        try:
            fail(7)
        except ValueError:
            _bi_gc_collect()
            raise KeyError
    except KeyError:
        _bi_gc_collect()
        total = total + 100
    return total


managed_entry()
