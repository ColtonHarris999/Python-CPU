"""STORE_ATTR twice on the same name — upsert, used unchanged.

# pycore-inject: SEED_INSTANCE o slots=4
"""


def managed_entry():
    o.x = 1
    o.x = 9
    return o.x


managed_entry()
