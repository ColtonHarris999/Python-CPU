"""GC steady state, lists (gc_plan.md G11): 1,000 build-and-drop iterations.

Each iteration's working set is a few hundred bytes; the Makefile target
shrinks the heap so the run collects many times. Live bytes at every
collection stay within one iteration's working set, and free bytes do not
shrink over the run.
"""


def managed_entry():
    total = 0
    keep = [total, total, total]
    for i in range(1000):
        a = [i, i + 1, "steady-list-element-" + str(i % 7)]
        b = [a, [i], a[2]]
        c = b + [i % 5]
        keep[i % 3] = c[3]
        total = total + len(c) + len(a[2]) + b[1][0] % 3
    return total + keep[0] + keep[1] + keep[2]


managed_entry()
