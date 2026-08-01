"""Transform a method into a class method.

No classmethod object kind; LOAD_ATTR does not bind ``cls``. Image class
folding rejects ``@classmethod``. See classmethod.md.
"""


def classmethod(function):
    return 1 % 0
