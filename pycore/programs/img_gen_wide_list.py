"""GC gen Phase 0: a wide old list written at a few scattered indices.

A 20,000-slot list survives a collection (old), then each iteration stores a
few young objects at scattered indices and collects. The written slots are
read back at the end; a lost young object changes the checksum or crashes.
"""

N = 20000


def managed_entry():
    old = [None] * N
    _bi_gc_collect()
    idx = 1
    for it in range(4):
        for j in range(4):
            idx = (idx * 7919 + 13) % N
            old[idx] = ["young-wide-" + str(it) + "-" + str(j), idx]
        _bi_gc_collect()
    total = 0
    for i in range(N):
        v = old[i]
        if v is not None:
            total = total + len(v[0]) + v[1]
    return total


managed_entry()
