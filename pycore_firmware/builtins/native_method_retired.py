"""Placeholder for STRACC-native method table holes (indices 6-9).

LOAD_ATTR for join/find/startswith/endswith returns a sentinel CODE_OBJECT
at 0xFFFF_0000 | index; CALL never enters this body.
"""


def native_method_retired(self):
    return None
