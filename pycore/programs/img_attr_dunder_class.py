"""LOAD_ATTR __class__ returns the instance's OBK_TYPE.

TYPE.__class__ → self on pycore (not host ``type``); only instances are
compared against the host golden.

# pycore-inject: SEED_TYPE T
# pycore-inject: SEED_INSTANCE o type=T slots=4
"""


def managed_entry():
    if o.__class__ is T:
        return 1
    return 0


managed_entry()
