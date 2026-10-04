"""GC steady state, strings (gc_plan.md G11): concat, join, split, replace, drop."""


def managed_entry():
    total = 0
    for i in range(1000):
        s = "steady-string-number-" + str(i) + "-with-tail"
        j = "|".join([s, "middle-part-of-join", str(i % 7)])
        parts = j.split("|")
        r = parts[0].replace("-", "+")
        total = total + len(parts) + len(r) + len(parts[1]) + len(j) % 11
    return total


managed_entry()
