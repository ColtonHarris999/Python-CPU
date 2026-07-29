"""Attribute found on the type, not the instance.

# pycore-inject: SEED_TYPE T x=99
# pycore-inject: SEED_INSTANCE o type=T slots=4
"""


def managed_entry():
    return o.x


managed_entry()
