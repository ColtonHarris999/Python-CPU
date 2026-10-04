"""GC precision: nothing unreachable is retained (gc_plan.md §6.4).

Covers the precision rows together, each checked by the oracle at every
collection:
- list capacity: `pop` leaves a stale reference past `length`;
- dict tombstones: a deleted entry's value slot keeps its old reference;
- empty tuples: zero-size tuples have no allocation;
- INT payloads equal to heap addresses are not pointers.
"""


def managed_entry():
    victim = ["popped-object-should-be-freed-1", "kept"]
    lst = [1, "kept-element-in-list", victim]
    lst.pop()
    victim = None
    d = {"x": ["dict-deleted-value-should-be-freed"], "y": 2}
    del d["x"]
    empties = [(), (), tuple()]
    addrs = [393216 + len(lst) - 3, 393232, 393248, 393264, 400000, 450048, 500000, 600000, 700000, 800000]
    garbage = ["garbage-at-some-address-" + str(len(addrs)), addrs[0]]
    garbage = None
    _bi_gc_collect()
    more = ["allocated-after-collection", 5]
    _bi_gc_collect()
    total = len(lst) + len(lst[1]) + d["y"] + len(d) + len(empties) + len(more[0]) + more[1]
    for a in addrs:
        total = total + a % 97
    return total


managed_entry()
