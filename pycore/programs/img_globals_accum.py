# Globals load across helpers via LOAD_GLOBAL, with mutation through a
# shared LIST cell (module init uses STORE_NAME; callees use LOAD_GLOBAL).
#
# managed_entry resets the cell so host differential runs (module exec +
# explicit entry call) stay deterministic.

cell = [0, 0]


def bump(delta):
    c = cell
    c[0] = c[0] + delta
    c[1] = c[1] + 1
    return c[0]


def snapshot():
    c = cell
    return c[0] + c[1] * 100


def managed_entry():
    c = cell
    c[0] = 0
    c[1] = 0
    bump(10)
    bump(7)
    bump(5)
    return snapshot()


managed_entry()
