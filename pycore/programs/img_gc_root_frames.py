"""GC: frame-descriptor roots (gc_plan.md §6.4 root_caller_frame, root_saved_globals,
root_ctor_instance).

- A caller's code object is reachable only from its frame descriptor: the
  compiled `g` is popped out of its namespace and called directly, so while
  its callee `h` collects, nothing else references `g`'s code.
- A globals dict passed to exec is reachable only as the running frame's
  globals.
- `__init__` collects while the new instance is held by the frame.
"""

SRC = """\
def g(n):
    r = h(n)
    return len(r[1]) + r[0]
"""

EXEC_SRC = "_bi_gc_collect()\nout[0] = len(payload[1]) + payload[0]\n"


def h(n):
    _bi_gc_collect()
    junk = [n, n, n]
    junk = None
    _bi_gc_collect()
    return [n, "callee-result-list"]


class Built:
    def __init__(self, n):
        _bi_gc_collect()
        self.n = n
        self.s = "constructed-instance-" + str(n)


def managed_entry():
    ns = {"h": h}
    exec(compile(SRC, "<s>", "exec"), ns)
    a = ns.pop("g")(4)
    ns = None
    out = [0]
    exec(compile(EXEC_SRC, "<e>", "exec"),
         {"out": out, "payload": [3, "exec-globals-owned-string"], "_bi_gc_collect": _bi_gc_collect})
    b = Built(9)
    _bi_gc_collect()
    return a * 10000 + out[0] * 100 + b.n + len(b.s)


managed_entry()
