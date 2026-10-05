"""GC: aliases stay valid and identity-hashed keys still hit after collection (gc_plan.md §6.4).

Instances used as dict keys hash by address; the collector never moves
objects, so lookups after collections find the same entries. Aliases held
in several containers all see one object.
"""


class Key:
    def __init__(self, n):
        self.n = n


def managed_entry():
    a = Key(1)
    b = Key(2)
    c = Key(3)
    d = {a: "value-for-key-a-long", b: "value-for-key-b-long", "s": 5, c: 7}
    alias = [a, b, (c, a)]
    junk = [Key(10), Key(11), {Key(12): 1}]
    junk = None
    _bi_gc_collect()
    more = [Key(20), "after-collection"]
    _bi_gc_collect()
    total = len(d[a]) + len(d[alias[1]]) + d[alias[2][0]] + d["s"]
    alias[2][1].n = 40
    return total * 100 + a.n + len(more[1])


managed_entry()
