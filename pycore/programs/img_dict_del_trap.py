"""DELETE_SUBSCR on a dict — same-tag tombstone path (returns 0)."""


def managed_entry():
    d = {}
    d["k"] = 1
    del d["k"]
    # Miss after delete should not revive the key; return 0 on success.
    if "k" in d:
        return 1
    return 0


managed_entry()
