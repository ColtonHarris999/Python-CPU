"""TO_BOOL on containers: empty falsy, nonempty truthy."""


def managed_entry():
    out = 0
    if []:
        out += 1
    if [1]:
        out += 10
    if ():
        out += 100
    if (1,):
        out += 1000
    if {}:
        out += 10000
    d = {}
    d[1] = 2
    if d:
        out += 100000
    return out


managed_entry()
