"""STORE_ATTR then LOAD_ATTR on a seeded instance __dict__.

# pycore-inject: SEED_INSTANCE o slots=4
"""


def managed_entry():
    o.x = 5
    o.y = 7
    return o.x + o.y


managed_entry()
