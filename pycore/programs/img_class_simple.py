"""M4: module-level class with one method and one instance attr."""


class Point:
    def set_x(self, v):
        self.x = v

    def get_x(self):
        return self.x


def managed_entry():
    p = Point()
    p.set_x(7)
    return p.get_x()


managed_entry()
