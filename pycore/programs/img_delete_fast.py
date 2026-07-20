# Exercises DELETE_FAST via a local delete that does not reload the slot.
#
# `del x` emits DELETE_FAST after STORE_FAST.  Returning `y` (not `x`) keeps
# this test focused on DELETE_FAST alone (use-after-del is covered by
# img_load_fast_check_unbound).  A wrong stack effect or wrong local write
# address corrupts `y` and fails the entry-return check.


def managed_entry():
    x = 1
    y = 2
    del x
    return y


managed_entry()
