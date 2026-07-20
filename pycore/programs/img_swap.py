# Exercises SWAP via augmented list subscript assignment.
#
# `x[0] += 5` compiles to COPY/BINARY_OP/SWAP 3/SWAP 2/STORE_SUBSCR.
# The two SWAP ops reorder the stack so STORE_SUBSCR sees
# (value, container, key).  A broken SWAP leaves operands in the wrong
# order and corrupts the store (or traps), so the return of x[0] fails.

def managed_entry():
    x = [1, 2]
    x[0] += 5
    return x[0]


managed_entry()
