"""GC: no leak across many object kinds (live bytes return to a fixed baseline).

Each workload builds and drops a mix of objects. After a warm-up round the
program measures live bytes with `_bi_gc_collect()` (precise, so it is the
exact reachable set), runs the workload 45 more times, and measures again;
any growth fails, so even one byte per iteration is caught. A collector that retains garbage, or an allocation path that
leaves unreachable bytes marked, makes live bytes grow with the iteration
count. A small heap (HEAP_DYN_BYTES) also forces many allocation-triggered
collections in the middle of each workload.

Returns 1, or 1000 * workload + growth in bytes for the first leak.

# pycore-expect: 1
"""


class Node:
    def __init__(self, v):
        self.v = v
        self.peer = None

    def get(self):
        return self.v


def w_lists(i):
    a = []
    for k in range(20):
        a.append([k, i])
    a.extend([[i]] * 5)
    b = a + [i]
    a.pop()
    return len(b) + len(a)


def w_dicts(i):
    d = {}
    for k in range(24):
        d["k" + str(k)] = [k, i]
    d.pop("k3")
    e = {}
    e.update(d)
    n = 0
    for k, v in e.items():
        n = n + v[0]
    return n + len(d.keys())


def w_sets(i):
    s = set()
    for k in range(30):
        s.add(k * i)
    t = set()
    t.update(s)
    return len(t)


def w_strings(i):
    s = "steady-" + str(i)
    parts = []
    for k in range(8):
        parts.append(s + "-" + str(k) + "-padding-to-make-it-long")
    j = ",".join(parts)
    return len(j) + len(f"{i}:{s}")


def w_objects(i):
    a = Node(i)
    b = Node(i + 1)
    a.peer = b
    b.peer = a          # cycle
    m = a.get
    return m() + b.peer.get()


def w_exceptions(i):
    n = 0
    for k in range(4):
        try:
            raise ValueError("bad " + str(k))
        except ValueError as e:
            n = n + len(e.args)
    return n


def w_cycles(i):
    a = [i]
    a.append(a)
    b = [a]
    a.append(b)
    t = (a, b)
    return len(t[0])


def w_calls(i):
    def f(*args, **kw):
        return len(args) + len(kw)
    return f(1, 2, i, x=1, y=[i]) + f(*[i, i], **{"z": i})


def w_iters(i):
    n = 0
    for c in "iterate-" + str(i):
        n = n + 1
    for k in {"a": 1, "b": 2}:
        n = n + 1
    for v in (i, i + 1, i + 2):
        n = n + v
    for r in range(i % 5, 10, 2):
        n = n + r
    return n


WORK = (w_lists, w_dicts, w_sets, w_strings, w_objects, w_exceptions,
        w_cycles, w_calls, w_iters)


def run(w, lo, hi):
    acc = 0
    for i in range(lo, hi):
        acc = acc + w(i)
    return acc


def managed_entry():
    idx = 0
    for w in WORK:
        idx = idx + 1
        run(w, 0, 5)
        base = _bi_gc_collect()
        run(w, 5, 50)
        after = _bi_gc_collect()
        if after > base:
            return 1000 * idx + (after - base)
    return 1


managed_entry()
