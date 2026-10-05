"""LOAD_ATTR method bind (G9 row 24): a fresh bound-method each iteration."""


class Adder:
    def add(self, x):
        return x + 1


def managed_entry():
    obj = Adder()
    total = 0
    keep = None
    for i in range(800):
        keep = obj.add
        total = total + keep(i)
    return total + (0 if keep is None else 1)


managed_entry()
