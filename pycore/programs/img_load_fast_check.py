# Exercises LOAD_FAST_CHECK on a bound local (maybe-unbound compile shape).
#
# `if cond: a = 7; return a` emits LOAD_FAST_CHECK for `a`.  With cond=1 the
# store always runs, so hardware must push INT 7 (not trap).  Wrong unbound
# check or wrong local index fails the entry-return check.


def managed_entry():
    cond = 1
    if cond:
        a = 7
    return a


managed_entry()
