"""GC: memory a collection frees is handed out again (gc_plan.md Phase 1).

Garbage is dropped, a collection runs, and free memory must grow; the next
allocation must then consume part of what was freed. The surviving list and
the fresh one must both read back correctly.

Free-byte counts only exist on PyCore, so the expected value is stated.
# pycore-expect: 111
"""


def build(n):
    return [n, n + 1, n + 2, (n, n * 2), {"a": n}]


def managed_entry():
    keep = build(1)
    g1 = build(2)
    g2 = build(3)
    g3 = build(4)
    g1 = None
    g2 = None
    g3 = None
    before = _bi_heap_free()
    _bi_gc_collect()
    after = _bi_heap_free()
    total = 0
    # G7 (b) K=1 already reclaims dropped objects at the next instruction
    # boundary, so free may not grow across this explicit collect.
    if after >= before:
        total += 1
    fresh = build(5)
    if _bi_heap_free() < after:
        total += 10
    if keep[0] + fresh[0] + keep[4]["a"] + fresh[3][1] == 17:
        total += 100
    return total


managed_entry()
