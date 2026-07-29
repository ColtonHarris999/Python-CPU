"""len() builtin on a tuple — pycore-native, no LIST_EXTEND."""


def managed_entry():
    return len((1, 2, 3))


managed_entry()
