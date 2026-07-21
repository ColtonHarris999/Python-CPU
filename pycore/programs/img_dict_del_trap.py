"""DELETE_SUBSCR on a dict → PY_TRAP_TYPE (tombstones deferred)."""


def managed_entry():
    d = {}
    d["k"] = 1
    del d["k"]
    return 0


managed_entry()
