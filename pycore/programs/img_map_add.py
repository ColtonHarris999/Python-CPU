"""MAP_ADD (dict[key]=value, pop 2) exercised directly.

compile() only emits MAP_ADD inside dict comprehensions, which also emit
RERAISE cleanup that hardware defers. The MAP_ADD_SEQ pragma hand-assembles
BUILD_MAP 0 + a run of MAP_ADD inserts (leaving the dict on the stack) and then
returns the sum of the stored values. Five keys into a 4-slot dict crosses the
2/3 load factor, so the run also drives the DICT_GROW trap path
(needs EXCORE_EN=1 / two-core).
"""

# pycore-inject: MAP_ADD_SEQ managed_entry 1 1 2 2 3 3 4 4 5 5


def managed_entry():
    d = {}
    d[1] = 1
    d[2] = 2
    d[3] = 3
    d[4] = 4
    d[5] = 5
    return d[1] + d[2] + d[3] + d[4] + d[5]


managed_entry()
