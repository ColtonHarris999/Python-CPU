"""GC gen Phase 0: STORE_GLOBAL / STORE_NAME of young objects after a collection.

Module globals (and the globals dict) survive a collection, then a function
rebinds them with `global` to freshly allocated objects, and a new global is
created. A second collection runs before everything is read back.
"""

A = ["module-global-a-initial", 0]
B = ("module-global-b-initial", 0)
LIST = [1, 2, 3]


def fresh(n):
    return ["young-global-value-" + str(n), n]


def rebind(n):
    global A, B, C
    A = fresh(n)
    B = (fresh(n + 1), "tuple-around-young")
    C = {"c": fresh(n + 2)}


def managed_entry():
    global LIST
    _bi_gc_collect()
    rebind(10)
    LIST = [fresh(20), fresh(21)]
    t = fresh(30)
    t = None
    _bi_gc_collect()
    total = len(A[0]) + A[1]
    total = total * 3 + len(B[0][0]) + B[0][1] + len(B[1])
    total = total * 3 + len(C["c"][0]) + C["c"][1]
    total = total * 3 + len(LIST[0][0]) + LIST[1][1]
    return total


managed_entry()
