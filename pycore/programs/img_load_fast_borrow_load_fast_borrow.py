# Exercises LOAD_FAST_BORROW_LOAD_FAST_BORROW via consecutive local loads.
#
# `return a + b` compiles to LOAD_FAST_BORROW_LOAD_FAST_BORROW 1 (a, b)
# then BINARY_OP +.  Wrong nibble order or a single push silently yields
# the wrong sum.

def managed_entry():
    a = 3
    b = 4
    return a + b


managed_entry()
