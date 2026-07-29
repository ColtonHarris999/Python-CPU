"""Type call runs __init__; return instance (ret_discard_push_self), not None.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_TYPE_METHOD T __init__ = init_t
"""


def init_t(self):
    self.x = 11


def managed_entry():
    o = T()
    return o.x


managed_entry()
