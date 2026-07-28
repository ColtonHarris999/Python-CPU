"""Fourth new-key insert on empty dict → fatal DICT_GROW without excore.

Single-core (EXCORE_EN=0) expects trap code 11.
"""


def managed_entry():
    d = {}
    d[0] = 1
    d[1] = 2
    d[2] = 3
    d[3] = 4
    return 0


managed_entry()
