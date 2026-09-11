"""Native dict methods: get, keys, items, update, pop, values.

keys/items/values materialize lists (LIST_EXTEND → two-core).
Expected: 16.
"""


def managed_entry():
    d = {}
    d["a"] = 1
    d["b"] = 2
    n = d.get("a") + d.get("z", 3)
    n = n + len(d.keys())
    n = n + len(d.items())
    d.update({"c": 4})
    n = n + d["c"]
    n = n + d.pop("b")
    n = n + len(d.values())
    return n


managed_entry()
