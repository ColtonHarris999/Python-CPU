"""STORE_NAME that grows the globals dict inside a for loop.

The excore DICT_GROW handler used to pop 3 for STORE_NAME (the STORE_SUBSCR
count), but the hart synthesizes the dict and the name -- only the value is on
the stack. The two extra pops ate the loop iterator, and the next FOR_ITER
TYPE-trapped. Host-compiled images pre-bind every stored name, so only
exec'd code hit it. The names below are first bound inside the loop on
purpose. Expected result: 6.
"""

SRC = """\
acc = 0
for k in [1, 2, 3]:
    g0 = k
    g1 = k
    g2 = k
    g3 = k
    g4 = k
    g5 = k
    g6 = k
    g7 = k
    g8 = k
    g9 = k
    g10 = k
    g11 = k
    acc = acc + k
done = acc
"""

done = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    return done


managed_entry()
