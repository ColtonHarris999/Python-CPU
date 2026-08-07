"""LOAD_ATTR __dict__ returns the live instance dict handle.

# pycore-inject: SEED_INSTANCE o slots=4
"""


def managed_entry():
    o.x = 5
    o.y = 7
    d = o.__dict__
    return d["x"] + d["y"]


managed_entry()
