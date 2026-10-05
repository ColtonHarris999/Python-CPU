"""gc_fuzz seed 20 (growth=False, compile=True).

G8 shrunk 2.5× peak trapped code=7 (largest hole 25 KB) when the loop
also emitted SET/DICT bulk updates. Measure on the full heap PASSES
(0x1f66b). Not in pycore-img-gc-all; generator keeps compile seeds
free of those loop templates.
"""


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


def _kwmerge(**k):
    return len(k)


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
    ns = {}
    exec(compile(ADDER_SRC, "<s>", "exec"), ns)
    make_adder = ns["make_adder"]
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
    _cov_t = (*_r,)
    acc = acc + len(_cov_t)
    acc = acc + len("cov-a-b-c".split("-"))
    acc = acc + len(range(0, 20, 5))
    acc = acc + Adder(1).add(2)
    _cov_st = (acc + 1, acc + 2, acc + 3, acc + 4)
    _cov_s = {*_cov_st}
    acc = acc + len(_cov_s)
    _cov_da = {"a": acc + 1, "b": acc + 2}
    _cov_db = {"c": acc + 3, "d": acc + 4, "e": acc + 5}
    _cov_du = {**_cov_da, **_cov_db}
    acc = acc + len(_cov_du)
    acc = acc + _kwmerge(**{"a": acc + 1, "b": acc + 2}, **{"c": acc + 3, "d": acc + 4})
    _c = make_adder(3)
    acc = acc + _c(4)
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
    for it in range(9):
        X3 = Box(10, varf(*T2, **{"p": L2[1], "q": 89}))
        N1.a = Box(2, L2)
        S1 = {5, 40, 96, it + 188}
        N1 = Node(Box(0, 32), X2)
        D0["a"] = Box(0, 94)
        X1 = Box(10, varf(X2, L3, kw=80))
        for ch in "ab":
            acc = acc + ord(ch)
        _cov_s = {*(acc + 1, acc + 2, acc + 3, acc + 4)}
        acc = acc + len(_cov_s)
        T0 = (L0[0], X2, Box(5, S1))
        L2[0] = L0[0]
        X4 = Box(5, S0)
        acc = acc + weigh(X1, 2)
        X2 = Box(9, Q1.split("-"))
        acc = acc + _kwmerge(**{"a": acc + 1, "b": acc + 2}, **{"c": acc + 3, "d": acc + 4})
        X2 = Box(10, varf(Box(3, T0), L3, kw=76))
        L1 = [N2.b, X1, Box(3, T2)]
        del D0["b"]
        D0["b"] = L3[0]
        Q1 = "-".join((Q0, Q2, "zz"))
        L1 = [Box(6, N0), Box(0, 97), X0]
        X0 = Box(9, Q1.partition("-"))
        D1 = {"a": X3, "b": Box(0, it + 59), "c": Box(0, it + 26)}
        D1 = {"a": Box(0, 56), "b": Box(1, Q1), "c": Box(6, N0)}
        del D2["b"]
        D2["b"] = X4
        Q0 = Q2.replace("-", "+-")
        Q2 = "-".join((Q0, Q2, "zz"))
        D1["b"] = Box(5, S0)
        X4 = N1.a
        L1[1] = N1.b
        D2["c"] = X0
        X3 = Box(10, varf(*T1, **{"p": L1[2], "q": 0}))
        acc = acc % 1000003
    total = acc + F0(1) + F1(2)
    total = total + weigh(Box(2, L0), 0)
    total = total + weigh(Box(2, L1), 0)
    total = total + weigh(Box(2, L2), 0)
    total = total + weigh(Box(2, L3), 0)
    total = total + weigh(Box(3, T0), 0)
    total = total + weigh(Box(3, T1), 0)
    total = total + weigh(Box(3, T2), 0)
    total = total + weigh(Box(4, D0), 0)
    total = total + weigh(Box(4, D1), 0)
    total = total + weigh(Box(4, D2), 0)
    total = total + len(S0)
    total = total + len(S1)
    total = total + weigh(Box(6, N0), 0)
    total = total + weigh(Box(6, N1), 0)
    total = total + weigh(Box(6, N2), 0)
    total = total + len(Q0)
    total = total + len(Q1)
    total = total + len(Q2)
    total = total + weigh(X0, 0)
    total = total + weigh(X1, 0)
    total = total + weigh(X2, 0)
    total = total + weigh(X3, 0)
    total = total + weigh(X4, 0)
    try:
        raise ValueError("exc-end-payload-long")
    except ValueError as ex:
        total = total + len(ex.args[0])
    return total % 1000000007


managed_entry()
