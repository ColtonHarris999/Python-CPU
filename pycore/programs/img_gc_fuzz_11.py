"""gc_fuzz seed 11 (growth=False, compile=False)."""


class Box:
    def __init__(self, kind, val):
        self.kind = kind
        self.val = val


class Node:
    def __init__(self, a, b):
        self.a = a
        self.b = b

    def get(self):
        return self.a


class Counter:
    def __init__(self, n):
        self.n = n
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i = self.i + 1
        return (self.i, "item-number-" + str(self.i))


class Adder:
    def __init__(self, k):
        self.k = k

    def add(self, x):
        return x + self.k


def make_plain(k):
    return Adder(k).add


ADDER_SRC = "def make_adder(k):\n    def add(x):\n        return x + k\n    return add\n"


def varf(*args, **kwargs):
    return (args, kwargs)


def helper(b):
    return [b, (b, 1), "helper-result-" + str(len(varf(b)))]


def deep(n, acc):
    a = [n, acc]
    b = (n, a)
    if n == 0:
        return acc
    return deep(n - 1, acc + len(b))


def weigh(b, d):
    # Values are boxed with their kind: `isinstance` only knows user classes.
    if d > 3:
        return 1
    k = b.kind
    v = b.val
    if k == 0:
        return v % 1000
    if k == 1:
        return len(v) * 3 + v.find("-") + 1
    if k == 2 or k == 3:
        total = 11 + k
        for e in v:
            total = total + weigh(e, d + 1)
        return total
    if k == 4:
        total = 17 + len(v)
        for key in v:
            total = total + len(key) + weigh(v[key], d + 1)
        return total
    if k == 5:
        return 19 + len(v)
    if k == 6:
        return 23 + weigh(v.a, d + 1) + weigh(v.b, d + 1)
    if k == 7:
        return 2
    if k == 9:
        total = 31
        for s in v:
            total = total + len(s)
        return total
    if k == 10:
        return 37 + len(v[0]) + len(v[1])
    return 29


def managed_entry():
    acc = 0
    it = 0
    make_adder = make_plain
    X0 = Box(0, 0)
    X1 = Box(0, 1)
    X2 = Box(0, 2)
    X3 = Box(0, 3)
    X4 = Box(0, 4)
    Q0 = "string-number-" + str(0) + "-with-a-tail"
    Q1 = "string-number-" + str(1) + "-with-a-tail"
    Q2 = "string-number-" + str(2) + "-with-a-tail"
    L0 = [Box(0, 0), Box(1, Q0), Box(7, None)]
    L1 = [Box(0, 1), Box(1, Q1), Box(7, None)]
    L2 = [Box(0, 2), Box(1, Q2), Box(7, None)]
    L3 = [Box(0, 3), Box(1, Q0), Box(7, None)]
    T0 = (Box(0, 0), X0, Box(2, L0))
    T1 = (Box(0, 1), X1, Box(2, L1))
    T2 = (Box(0, 2), X2, Box(2, L2))
    D0 = {"a": Box(0, 0), "b": Box(7, None), "c": X0}
    D1 = {"a": Box(0, 1), "b": Box(7, None), "c": X1}
    D2 = {"a": Box(0, 2), "b": Box(7, None), "c": X2}
    S0 = {1, 2, 3, acc + 10}
    S1 = {1, 2, 3, acc + 11}
    N0 = Node(Box(0, 0), Box(7, None))
    N1 = Node(Box(0, 1), Box(7, None))
    N2 = Node(Box(0, 2), Box(7, None))
    F0 = make_adder(0)
    F1 = make_adder(1)
    R0 = range(0, 1099511627776, 7)
    _u, *_r = [Box(0, 1), Box(0, 2), Box(0, 3)]
    acc = acc + len(_r) + len(set((1, 2, 3)))
    acc = acc + len("cov-a-b-c".split("-"))
    acc = acc + len(range(0, 20, 5))
    acc = acc + Adder(1).add(2)
    for e in L0:
        acc = acc + e.kind
        break
    for e in T0:
        acc = acc + e.kind
        break
    for k in D0:
        acc = acc + len(k)
        break
    for e in S0:
        acc = acc + e
    for ch in "ab":
        acc = acc + ord(ch)
        break
    for i in range(2):
        acc = acc + i
        break
    for p in Counter(2):
        acc = acc + p[0]
        break
    for it in range(8):
        L2 = [Box(4, D1), L1[0], Box(6, N0), Box(3, T2)]
        D0["b"] = Box(7, None)
        Q0 = Q0[0:20] + "-" + str(70) + "-tail-of-string"
        X2 = Box(5, set((95, 29, 172)))
        N1.a = Box(7, None)
        L1[1] = Box(0, 5)
        for ch in Q1:
            acc = acc + ord(ch) % 7
        N1 = Node(Box(4, D0), Box(2, L1))
        for p in Counter(4):
            acc = acc + p[0] + len(p[1])
        L0[0] = Box(1, Q2)
        D2["a"] = Box(3, T1)
        T0 = (L3[1], Box(0, it + 93)) + (L0[2],)
        X0 = Box(9, Q1.split("-"))
        L0 = [X3, N0.a, L0[2]]
        acc = acc + deep(36, 0)
        Q0 = Q1.replace("-", "+-")
        X0 = Box(10, varf(X4, L0, kw=34))
        acc = acc % 1000003
    return acc


managed_entry()
