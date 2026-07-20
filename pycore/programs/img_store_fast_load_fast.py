# Exercises STORE_FAST_LOAD_FAST via a same-line store-then-use.
#
# `a = 9; return a + b` compiles to STORE_FAST_LOAD_FAST (a, a) followed by
# LOAD_FAST_BORROW b / BINARY_OP +.  A broken SFLF (wrong local, stale reload
# when hi==lo, or bad stack delta) returns the wrong sum.

def managed_entry():
    a = 1
    b = 2
    a = 9; return a + b


managed_entry()
