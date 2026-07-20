# Exercises LOAD_FAST_AND_CLEAR via image-builder inject.
#
# Natural comprehension emission also needs GET_ITER/FOR_ITER/LIST_APPEND
# (deferred).  The pragma rewrites the first load of `x` to opcode 85 so the
# image path can prove push-then-clear without those siblings.  Host return
# matches the unpatched source (z gets 5, y stays 2).  A wrong clear target
# corrupts y; a wrong stack effect breaks the sum.
#
# pycore-inject: LOAD_FAST_AND_CLEAR managed_entry x


def managed_entry():
    x = 5
    y = 2
    z = x
    return z + y


managed_entry()
