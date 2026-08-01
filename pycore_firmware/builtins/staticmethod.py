"""Transform a method into a static method.

Image convention: OBK_BUILTIN id=0 (BI_STATICMETHOD) wrapping a
CODE_OBJECT — applied at image-build time, not by this callable.
"""


def staticmethod(function):
    # Runtime wrapper allocation is not available; image folding handles
    # @staticmethod. Calling this firmware entry is a hard blocker.
    return 1 % 0
