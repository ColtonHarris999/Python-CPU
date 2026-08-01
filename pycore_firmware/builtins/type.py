"""Return the type of an object, or create a type.

One-arg: ``obj.__class__`` (image instance model).
Three-arg dynamic type creation needs LOAD_BUILD_CLASS (deferred).
"""


def type(obj, bases=None, dct=None):
    if bases is None:
        if dct is None:
            return obj.__class__
    # Three-arg form blocked
    return 1 % 0
