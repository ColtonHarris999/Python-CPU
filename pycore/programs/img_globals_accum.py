# Module globals round-trip across helpers via STORE_GLOBAL / LOAD_GLOBAL.

total = 0
steps = 0


def bump(delta):
    global total
    global steps
    total = total + delta
    steps = steps + 1
    return total


def double_total():
    global total
    total = total + total
    return total


def managed_entry():
    bump(10)
    bump(7)
    double_total()
    bump(steps)
    return total


managed_entry()
