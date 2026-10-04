"""G10 mutant 43 (B13): an empty-string iterator is not a heap pointer.

GET_ITER on an empty SHORT_STR writes an ITER with addr 0 and no spill
word. A collection at the boundary between GET_ITER and FOR_ITER sees it
on the stack; decoding it as a LONG_STR at address 0 is a wild pointer.
"""


def managed_entry():
    total = 0
    for word in ("ab", "", "c", ""):
        for c in word:
            total += 1
        for c in "":
            total += 10
    return total


managed_entry()
