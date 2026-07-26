"""LIST NB_INPLACE_ADD grows the live iterator source.

Appending 3 while visiting 1 extends the current list. FOR_ITER must observe
the new length and yield the appended tail. Expected result: 1 + 2 + 3 = 6.
"""


def managed_entry():
    xs = [1, 2]
    total = 0
    for x in xs:
        total += x
        if x == 1:
            xs += [3]
    return total


managed_entry()
