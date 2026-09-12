"""INT.__class__ still TYPE (1); not a native-method receiver."""


def managed_entry():
    x = 1
    return x.__class__


managed_entry()
