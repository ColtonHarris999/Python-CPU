"""GC: a collection right after boot sees only static roots (gc_plan.md §6.4).

The first collection after reset clears the bitmap (no sweep ran before) and
finds no dynamic object; the second one runs from the swept state.
"""


def managed_entry():
    _bi_gc_collect()
    x = [1, "allocated-after-the-boot-collection"]
    _bi_gc_collect()
    return len(x[1]) * 10 + x[0]


managed_entry()
