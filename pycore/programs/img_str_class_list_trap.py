"""LIST.__class__ still ATTR_ERROR (15); only STR is special-cased."""


def managed_entry():
    xs = []
    return xs.__class__


managed_entry()
