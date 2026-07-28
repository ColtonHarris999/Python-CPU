"""MAP_ADD with dict grow: insert enough pairs to trigger DICT_GROW (excore).

Inserts 5 pairs into an empty dict — initial empty table → DICT_GROW
on first insert, then continued inserts.
Expected: d[1]+d[2]+d[3]+d[4]+d[5] = 2+4+6+8+10 = 30.
"""

# pycore-inject: MAP_ADD_SEQ managed_entry (1,2) (2,4) (3,6) (4,8) (5,10) MODE=SUBSCR


def managed_entry():
    d = {}
    d[1] = 2
    d[2] = 4
    d[3] = 6
    d[4] = 8
    d[5] = 10
    return d[1] + d[2] + d[3] + d[4] + d[5]


managed_entry()
