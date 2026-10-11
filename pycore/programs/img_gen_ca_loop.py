"""GC gen Phase 4: container-accelerator commands on old owners.

One explicit collection makes a set of containers old. A loop then grows
them through the container accelerator (or, with +CA_EN=0 on the two-core
top, the excore traps that replace it): appends past capacity (L_APPEND),
in-place extends into spare capacity (L_EXTEND), middle deletes (L_DEL),
new dict keys and instance attributes (D_GROW) and new set elements
(S_GROW). Each stores a fresh object into an old owner, or points an old
owner at a fresh buffer or table. Churn between iterations lets
`+GC_AT_BOUNDARY_EVERY` minors land inside the loop; every value is read
back at the end.
"""


class Box:
    pass


def churn(n):
    t = None
    for i in range(n):
        t = ("churn", i, [i, i])
    return t


def set_attr(b, k, v):
    # A new attribute each time: the instance dict grows (D_GROW).
    if k == 0:
        b.a0 = v
    elif k == 1:
        b.a1 = v
    elif k == 2:
        b.a2 = v
    elif k == 3:
        b.a3 = v
    elif k == 4:
        b.a4 = v
    elif k == 5:
        b.a5 = v
    elif k == 6:
        b.a6 = v
    else:
        b.a7 = v


def get_attr(b, k):
    if k == 0:
        return b.a0
    if k == 1:
        return b.a1
    if k == 2:
        return b.a2
    if k == 3:
        return b.a3
    if k == 4:
        return b.a4
    if k == 5:
        return b.a5
    if k == 6:
        return b.a6
    return b.a7


def managed_entry():
    grow = []
    for i in range(10):
        grow.append([i])
    ext = []
    for i in range(10):
        e = [[0], [1], [2], [3]]
        e.append([4])
        ext.append(e)
    dicts = []
    for i in range(6):
        dicts.append({"base": i})
    sets = []
    for i in range(6):
        sets.append({i})
    boxes = []
    for i in range(4):
        b = Box()
        b.base = i
        boxes.append(b)
    _bi_gc_collect()
    for it in range(30):
        for i in range(10):
            grow[i].append(["grow", it, i])
        for i in range(10):
            e = ext[i]
            e.extend([("ext", it), ["ext", i, it]])
            del e[1]
            del e[1]
        for i in range(6):
            dicts[i]["k" + str(it)] = ["dv", it, i]
            sets[i].add("sv-" + str(it) + "-" + str(i))
        set_attr(boxes[it % 4], it // 4, ["attr", it])
        churn(10 + it % 7)
    total = 0
    for i in range(10):
        g = grow[i]
        total = total + len(g) + g[0]
        for j in range(1, len(g)):
            total = total + g[j][1] * 3 + g[j][2]
        e = ext[i]
        total = total + len(e)
        for j in range(len(e)):
            v = e[j]
            total = total + v[len(v) - 1] * (j + 1)
    for i in range(6):
        d = dicts[i]
        total = total + d["base"]
        for it in range(30):
            v = d["k" + str(it)]
            total = total + v[1] + v[2]
        s = sets[i]
        for it in range(30):
            if ("sv-" + str(it) + "-" + str(i)) in s:
                total = total + it + 1
    for it in range(30):
        b = boxes[it % 4]
        total = total + get_attr(b, it // 4)[1] + b.base
    return total


managed_entry()
