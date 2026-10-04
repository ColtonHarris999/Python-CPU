"""GC steady state, sets (gc_plan.md G11): 1,000 build-and-drop iterations."""


def managed_entry():
    total = 0
    for i in range(1000):
        s = {i % 11, i % 13, i % 17, i + 1000}
        t = set((i % 3, i % 5, 99))
        s.add(i % 11)
        if (i % 13) in s:
            total = total + 1
        total = total + len(s) + len(t)
    return total


managed_entry()
