"""Hash value of an object.

Hashing is internal to dict/set probe paths and not exposed as a callable
primitive to pure Python.
"""


def hash(obj):
    return 1 % 0
