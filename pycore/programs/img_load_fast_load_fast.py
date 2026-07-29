# Exercises LOAD_FAST_LOAD_FAST (+ STORE_FAST_STORE_FAST sibling) via swap.
#
# `a, b = b, a` compiles to LOAD_FAST_LOAD_FAST 16 (b, a) then
# STORE_FAST_STORE_FAST 16 (b, a).  Returning `a` after the swap must be 2;
# inverted nibble order or stack pops silently yield the wrong entry.

def managed_entry():
    a = 1
    b = 2
    a, b = b, a
    return a


managed_entry()
