"""GC steady state, dicts (gc_plan.md G11): 1,000 build/update/delete/drop iterations."""


def managed_entry():
    total = 0
    for i in range(1000):
        d = {"a": i, "b": "steady-dict-value-" + str(i % 9), None: [i], 7: (i, i)}
        d["a"] = d["a"] + 1
        del d[7]
        d[7] = i % 4
        total = total + d["a"] % 5 + len(d["b"]) + d[None][0] % 3 + d[7] + len(d)
    return total


managed_entry()
