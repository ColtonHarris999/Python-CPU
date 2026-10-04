"""Compile-built CELL/FUNCTION plus a live exception (G8 seed 2).

`exec(compile(...))` then `raise`/`except` keeping the exception, then
calling the compiled closure, then enough work for a boundary collection,
hits `[GC-INV] bad_kind` (seed 2 collection 260). Not in pycore-img-gc-all
until the collector traces this graph.
"""

ADDER_SRC = "def make_adder(k):\n    def add(x):\n        return x + k\n    return add\n"


def managed_entry():
    ns = {}
    exec(compile(ADDER_SRC, "<s>", "exec"), ns)
    make_adder = ns["make_adder"]
    add = make_adder(3)
    try:
        raise ValueError("exc-end-payload-long")
    except ValueError as ex:
        keep = ex
    acc = add(1)
    acc = acc + len(keep.args[0])
    return acc


managed_entry()
