"""GC gen Phase 5: chunk-refined entries for large lists.

A store into a list longer than one scan chunk (128 slots) logs only the
chunk that holds the slot. One explicit collection makes two large lists
old; a loop then stores fresh objects into two different chunks of the
big list per iteration (one of them in the last, partial chunk), and
deletes from the middle of the other list, which shifts a young value
stored just past a chunk boundary into the chunk before it. Churn between
iterations lets `+GC_AT_BOUNDARY_EVERY` minors land inside the loop; every
value is read back at the end.
"""


def churn(n):
    t = None
    for i in range(n):
        t = ("churn", i, [i, i])
    return t


def managed_entry():
    big = [None] * 1000
    for i in range(1000):
        big[i] = [i, 0]
    shift = [None] * 400
    for i in range(400):
        shift[i] = [i, 0]
    _bi_gc_collect()
    for it in range(24):
        a = (it * 37) % 1000
        b = 999 - (it * 53) % 104
        big[a] = ["a", it]
        big[b] = ("b", it)
        # The value lands at the first slot of a chunk; the delete moves it
        # to the last slot of the chunk before.
        shift[128 + 128 * (it % 2)] = ["s", it, 0]
        del shift[3]
        churn(9 + it % 5)
    total = 0
    for i in range(1000):
        total = total + big[i][1] * 3 + 1
    for i in range(len(shift)):
        total = total + shift[i][1] * (i + 1) + len(shift[i])
    return total


managed_entry()
