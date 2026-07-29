"""Type call with no __init__ → bare instance; store and read an attr.

# pycore-inject: SEED_TYPE T
"""


def managed_entry():
    o = T()
    o.x = 7
    return o.x


managed_entry()
