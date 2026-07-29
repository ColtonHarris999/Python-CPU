"""Delete then re-store the same name — tombstone reuse.

# pycore-inject: SEED_INSTANCE o slots=4 x=1
"""


def managed_entry():
    del o.x
    o.x = 42
    return o.x


managed_entry()
