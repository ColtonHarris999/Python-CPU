# Exercises the NOP opcode left by dead-branch elimination.
#
# `if False: pass` compiles to a NOP (CPython 3.14 peephole) between the
# STORE_FAST of x and the LOAD_FAST / RETURN_VALUE.  managed_entry returns
# 7; a broken NOP (illegal trap or stack corruption) fails the entry-return
# check.


def managed_entry():
    x = 7
    if False:
        pass
    return x


managed_entry()
