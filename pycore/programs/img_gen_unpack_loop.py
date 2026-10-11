"""GC gen Phase 3: DICT_UPDATE, SET_UPDATE and comprehension appends.

These sites write a container the same instruction sequence just built, so
the owner is young unless a collection lands between the build and the
update. The loop varies its instruction count per iteration, so with
`+GC_AT_BOUNDARY_EVERY` some collections (minors) fall between a BUILD_MAP
or BUILD_SET and the update that fills it with fresh objects, and between
the appends of a list comprehension.
"""


def pad(n):
    t = 0
    for i in range(n):
        t = t + i
    return t


def managed_entry():
    # Preallocated, so keeping a result is a list store (a barrier site),
    # not an append that the container accelerator grows (a guard hit,
    # which would make every collection a major).
    keep_d = [None] * 120
    keep_s = [None] * 120
    keep_l = [None] * 120
    _bi_gc_collect()
    for it in range(120):
        src = {"young-dict-update-key-" + str(it): ["young-dict-update-value", it]}
        s2 = {"second-key": ("second-young-value", it)}
        s3 = {"third-key": ["third-young-value", it]}
        # Each `**` is one DICT_UPDATE: a collection anywhere in the run of
        # updates leaves the later ones writing an old dict.
        d = {**src, **s2, **s3, **src, **s2, **s3}
        keep_d[it] = d
        s = {*("young-set-update-element-number-" + str(it),)}
        keep_s[it] = s
        lst = [["young-comprehension-item", it, j] for j in range(3)]
        keep_l[it] = lst
        pad(it % 7)
    total = 0
    for d in keep_d:
        for k in d:
            total = total + len(k) + d[k][1]
        total = total + d["second-key"][1] + len(d["third-key"][0])
    for s in keep_s:
        for e in s:
            total = total + len(e)
    for lst in keep_l:
        for item in lst:
            total = total + item[1] + item[2]
    return total


managed_entry()
