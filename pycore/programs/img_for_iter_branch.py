"""Branching loop body — COMPARE_OP + POP_JUMP_IF inside FOR_ITER.

Expected result: two values in (1, 5, 3) are > 2 → 2.
"""


def managed_entry():
    hits = 0
    for x in (1, 5, 3):
        if x > 2:
            hits += 1
    return hits


managed_entry()
