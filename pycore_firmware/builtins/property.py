"""Property descriptor with optional getter/setter/deleter.

Descriptor protocol (``__get__``/``__set__``) is not implemented on
LOAD_ATTR / STORE_ATTR. See property.md.
"""


def property(fget=None, fset=None, fdel=None):
    return 1 % 0
