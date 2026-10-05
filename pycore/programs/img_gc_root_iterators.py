"""GC: iterators as the only owners of their sources (gc_plan.md §6.4).

Each loop iterates over a freshly built container that nothing else
references, and collects inside the loop body: list, tuple, dict, set,
LONG_STR, SHORT_STR (its spill word), and range iterators (inline ranges;
iterating a wide range is not supported by the image path).
"""


def managed_entry():
    total = 0
    n = 3
    for s in ["list-iterator-owned-" + str(n), "second-list-element-long", str(n)]:
        _bi_gc_collect()
        total = total + len(s)
    for s in ("tuple-iterator-owned-" + str(n), "second-tuple-element-long", str(n)):
        _bi_gc_collect()
        total = total + len(s)
    for k in {"alpha": n, "beta-key-long-enough": n + 1, "gamma": 3}:
        _bi_gc_collect()
        total = total + len(k)
    for e in {n, n + 10, n + 20}:
        _bi_gc_collect()
        total = total + e
    for ch in "long-string-iterator-" + str(n):
        _bi_gc_collect()
        total = total + ord(ch) % 5
    for ch in "ab" + str(n):
        _bi_gc_collect()
        total = total + ord(ch)
    for i in range(n, n + 3):
        _bi_gc_collect()
        total = total + i
    return total


managed_entry()
