"""CALL allocation sites for G9 rows 24-28.

Exception construction stays in its own function so a live instance plus
GET_ITER on the caller does not TYPE-trap (B4/B11 family).
"""


class Adder:
    def add(self, x):
        return x + 1


def one_exc():
    try:
        raise ValueError("exc-payload-long-enough")
    except ValueError as ex:
        return len(ex.args)


def managed_entry():
    obj = Adder()
    total = 0
    keep_s = {0}
    keep_r = None
    for i in range(400):
        keep_r = range(0, 1099511627776, 7)
        keep_s = set((i, i + 1, i + 2))
        total = total + one_exc()
        total = total + obj.add(i)
        total = total + i
    extra = 0 if keep_r is None else 1
    return total + len(keep_s) + extra


managed_entry()
