"""DICT_GROW via STORE_ATTR then LOAD_GLOBAL — must not corrupt globals."""

MARKER = 99


class Box:
    def __init__(self):
        self.a = 1
        self.b = 2
        self.c = 3
        self.d = 4  # triggers instance-dict grow


def managed_entry():
    b = Box()
    return MARKER


managed_entry()
