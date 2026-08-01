"""Return a new featureless object.

Needs OBK_INSTANCE allocation without a user class body — not expressible
in pure Python on pycore (no ``object.__new__`` / heap helper). Blocked.
"""


def object():
    return 1 % 0
