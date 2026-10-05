"""G13 benchmark: a full live heap (gc_plan.md §10.2 G13 P3, P5, P7).

Builds a broad tree of small objects filling most of the ~600 KB dynamic
heap (the dynamic heap is [HEAP_INIT_PTR, 0xF0000)), then collects twice
with everything live. Lists are built by repetition and index stores, so no
container grows (the program runs on the single-core top).
"""


# Shared strings keep the live set in objects, not unique LONG_STR payloads.
# A tuple, not a list: CPython compiles a list display of constants as
# BUILD_LIST 0 + LIST_EXTEND, which is a fatal trap on the single-core top.
S = ("leaf-aaaa", "leaf-bbbb", "leaf-cccc", "leaf-dddd",
     "leaf-eeee", "leaf-ffff", "leaf-gggg", "leaf-hhhh")


def leaf(i):
    return (i, S[i % 8])


def branch(base):
    kids = [0] * 8
    for j in range(8):
        kids[j] = leaf(base + j)
    return kids


def managed_entry():
    # 64 B two-element tuples are line-aligned, so each tree is ~1.8 KB.
    # Dynamic heap after this image is ~598 KB; n=280 stays inside it.
    n = 280
    tree = [0] * n
    for i in range(n):
        tree[i] = [branch(i * 16), branch(i * 16 + 8), (i,)]
    _bi_gc_collect()
    _bi_gc_collect()
    total = 0
    for i in range(n):
        total = total + tree[i][0][3][0] % 7 + len(tree[i][1][5][1]) + tree[i][2][0] % 3
    return total


managed_entry()
