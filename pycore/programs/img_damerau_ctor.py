"""Folded class + __init__ + bound method — prefix of PyBGL memo Damerau."""


class Box:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def size(self):
        return len(self.x) + 10 * len(self.y)


def managed_entry():
    return Box("ab", "c").size()


managed_entry()
