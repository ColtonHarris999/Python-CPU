"""MAP_ADD: probe/insert for new keys; read back via subscript.

Uses MAP_ADD_SEQ pragma to hand-assemble BUILD_MAP + MAP_ADD sequences,
avoiding the RERAISE exception-cleanup code that dict comprehensions emit.
Expected: d[1]+d[2]+d[3] = 10+20+30 = 60.
"""

# pycore-inject: MAP_ADD_SEQ managed_entry (1,10) (2,20) (3,30) MODE=SUBSCR


def managed_entry():
    d = {}
    d[1] = 10
    d[2] = 20
    d[3] = 30
    return d[1] + d[2] + d[3]


managed_entry()
