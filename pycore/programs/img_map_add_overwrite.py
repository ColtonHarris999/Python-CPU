"""MAP_ADD with key overwrite: insert then re-insert same key (last value wins).

The MAP_ADD_SEQ inject inserts (1,10), (2,20), then (1,99) to overwrite key 1.
SUBSCR mode reads d[1]+d[2]+d[1] (once per pair), matching the host function.
d[1]=99 (overwritten), d[2]=20.  Result: 99+20+99 = 218.
"""

# pycore-inject: MAP_ADD_SEQ managed_entry (1,10) (2,20) (1,99) MODE=SUBSCR


def managed_entry():
    d = {}
    d[1] = 10
    d[2] = 20
    d[1] = 99
    return d[1] + d[2] + d[1]


managed_entry()
