# Negative: proves LOAD_FAST_AND_CLEAR actually CLEARS its source slot.
#
# The companion img_load_fast_and_clear.py proves the LOAD (push) half; this
# proves the CLEAR half.  The inject rewrites the first load of `x` (the
# `z = x` LOAD_FAST) to opcode 85 (LOAD_FAST_AND_CLEAR), which pushes x's
# value AND writes UNINIT back to x's slot.  The following `del x`
# (DELETE_FAST) then hits an already-unbound slot and traps
# PY_TRAP_MEM_FAULT (7) (deviation 11).
#
# If LFAC failed to clear, x would still be bound, DELETE_FAST would succeed,
# and no trap would fire -> the trap harness fails.  A passing trap-7 run
# therefore proves the clear happened.  Host runs the un-injected source
# (del x on a bound local is fine), so this uses PYCORE_IMAGE_TRAP_RUN.
#
# pycore-inject: LOAD_FAST_AND_CLEAR managed_entry x


def managed_entry():
    x = 5
    y = 2
    z = x
    del x
    return z + y


managed_entry()
