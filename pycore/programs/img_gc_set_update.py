"""SET_UPDATE TUPLE source only (G9 row 16). No dict traffic to steal the run."""


def managed_entry():
    total = 0
    keep = {0}
    for i in range(400):
        st = (i + 1, i + 2, i + 3, i + 4)
        keep = {*st}
        total = total + len(keep)
    return total


managed_entry()
