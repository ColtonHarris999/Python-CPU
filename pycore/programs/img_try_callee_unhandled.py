"""An exception unhandled through the module frame remains trap 17."""


def fail():
    raise ValueError


fail()
