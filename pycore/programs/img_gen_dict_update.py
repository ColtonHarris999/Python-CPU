"""GC gen Phase 0: dict.update of young objects into an old dict.

A dict survives a collection, then is updated twice from freshly built dicts
(new and existing keys, enough to grow the table). A second collection runs
before every value is read back. `old |= more` would be the other spelling,
but in-place `|` on a dict traps TYPE on PyCore today, so both use update().
"""


def fresh(n):
    return ["young-update-value-" + str(n), n]


def managed_entry():
    old = {"a": ("old", 1), "b": ("old", 2)}
    _bi_gc_collect()
    src = {}
    for i in range(12):
        src["upd-key-" + str(i)] = fresh(i)
    src["a"] = fresh(50)
    old.update(src)
    src = None
    more = {"b": fresh(60)}
    for i in range(12, 30):
        more["upd2-key-" + str(i)] = fresh(i)
    old.update(more)
    more = None
    _bi_gc_collect()
    total = len(old)
    total = total + len(old["a"][0]) + old["a"][1]
    total = total + len(old["b"][0]) + old["b"][1]
    for i in range(12):
        v = old["upd-key-" + str(i)]
        total = total + len(v[0]) + v[1] * 2
    for i in range(12, 30):
        v = old["upd2-key-" + str(i)]
        total = total + len(v[0]) + v[1] * 3
    return total


managed_entry()
