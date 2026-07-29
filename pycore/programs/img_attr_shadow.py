"""Instance attribute shadows a same-named class attribute.

# pycore-inject: SEED_TYPE T x=99
# pycore-inject: SEED_INSTANCE o type=T slots=4 x=5
"""


def managed_entry():
    return o.x


managed_entry()
