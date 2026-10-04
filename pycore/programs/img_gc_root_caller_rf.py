"""GC: caller RF slots below wm stay rooted (gc_plan.md §6.4).

A CALL that does not overflow the RF ring leaves the caller's locals in
slots below `rf_wm_r`. Those slots are not spilled, so a collection inside
the callee must still mark them. `keep` is reachable only from the caller's
RF; if the walker starts at wm it is freed and the return path traps or
returns garbage.
"""


def inner():
    _bi_gc_collect()
    drop = ["dropped-callee-temp-string"]
    drop = None
    _bi_gc_collect()
    return 1


def managed_entry():
    keep = [7, "only-reachable-from-caller-rf-slot"]
    n = inner()
    return n + keep[0] + len(keep[1])


managed_entry()
