"""List comp with LOAD_FAST_AND_CLEAR save/restore of an outer local.

CPython emits LOAD_FAST_AND_CLEAR for the comprehension target cell, then
restores the prior value (or clears) after the loop / on the exception path.
"""


def managed_entry():
    x = 100
    xs = [x for x in range(4)]
    # Outer x must be restored to 100 after the comprehension.
    total = 0
    for v in xs:
        total += v
    return total + x


managed_entry()
