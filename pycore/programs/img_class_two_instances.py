"""M4: two instances have independent __dict__ values."""


class Box:
    def set(self, v):
        self.v = v

    def get(self):
        return self.v


def managed_entry():
    a = Box()
    b = Box()
    a.set(10)
    b.set(20)
    return a.get() + b.get()


managed_entry()
