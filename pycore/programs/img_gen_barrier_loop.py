"""GC gen Phase 3: every pycore barrier site, with minors in between.

One explicit collection makes a set of containers old. A loop then stores
fresh objects into them through each site that writes an existing owner
without growing it (list store into many lists, spare-capacity append and
last-element delete, dict overwrite, attribute overwrite, delete and
re-add, a contaminated dict.update), and churns between iterations so that
`+GC_AT_BOUNDARY_EVERY` collections land inside the loop. Those are minors,
so each one depends on the remembered set. A dict comprehension at the end
spans several collections while its dict is old. Every value is read back.
"""


G = ["module-global-initial", 0]


class Box:
    pass


def churn(n):
    t = None
    for i in range(n):
        t = ("churn", i, [i, i])
    return t


def set_global(it):
    global G
    G = ["module-global-young", it]


def managed_entry():
    lists = []
    for i in range(40):
        lst = []
        for j in range(6):
            lst.append(j)
        lists.append(lst)
    d = {}
    for i in range(8):
        d["k" + str(i)] = i
    b = Box()
    b.a = 1
    b.b = 2
    b.c = 3
    b.d = 4
    key = Box()
    u = {key: 0}
    for i in range(3):
        u["u" + str(i)] = i
    _bi_gc_collect()
    for it in range(30):
        for i in range(40):
            lists[i][it % 6] = [it, i]
        lists[it % 40].append(["app", it])
        del lists[it % 40][6]
        d["k" + str(it % 8)] = ["dv", it]
        b.a = ["attr", it]
        del b.d
        b.d = ("dd", it)
        u.update({key: ["upd", it], "u1": ("u1", it)})
        set_global(it)
        # A young owner the barrier logs after the run it came from was
        # left behind: it is not dropped (B5) and it dies before the next
        # minor, which must skip it (B4).
        tmp = [0, 0, 0, 0]
        churn(12 + it % 5)
        tmp[it % 4] = ["tmp-young", it]
        tmp = None
    big = {i: [i, "big"] for i in range(200)}
    bl = [[i, "bl"] for i in range(200)]
    total = 0
    for i in range(40):
        for j in range(6):
            v = lists[i][j]
            total = total + v[0] * 7 + v[1]
    for i in range(8):
        total = total + d["k" + str(i)][1] * (i + 1)
    total = total + b.a[1] + b.d[1] + b.b + b.c
    total = total + u[key][1] + u["u1"][1] + u["u0"] + u["u2"]
    for i in range(200):
        total = total + big[i][0] + bl[i][0]
    total = total + G[1]
    return total


managed_entry()
