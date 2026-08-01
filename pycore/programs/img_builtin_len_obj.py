"""BI_LEN miss path: INSTANCE with __len__ on its type's tp_dict.

# pycore-inject: SEED_TYPE Box
# pycore-inject: SEED_TYPE_METHOD Box __len__ = box_len
"""


def box_len(self):
    return 5


def managed_entry():
    b = Box()
    return len(b)


managed_entry()
