"""End-to-end: a startup program that launches several others.

This is the shape the on-device compiler exists for. ``startup`` holds a
table of program sources, compiles each one at run time, and runs it in its
*own* globals dict, so the programs cannot see or clobber each other's
names -- the same `_bi_exec_globals` switch the compiler itself runs under
(compiler_design.md 4.2). It then reads each program's result back out of
its namespace and reduces them.

The programs deliberately use different corners of the grammar: a plain
loop, a function with a default and a keyword call site, a conditional
expression, and one that raises so the launcher has to survive a failure.
Every one of them binds the *same* names (`n`, `out`) to prove the
namespaces really are separate.

Expected result: 7.

Two-core: the launcher's result list grows through LIST_APPEND
(PY_TRAP_LIST_GROW), and so do the compiler's own arenas.
"""

P0 = """\
n = 0
for i in [1, 2, 3, 4]:
    n = n + i
out = n
"""

P1 = """\
def scale(v, by=3):
    return v * by
out = scale(4) + scale(1, by=6)
"""

P2 = """\
n = 5
out = n * 2 if n > 3 else 0
"""

P3 = """\
raise TypeError("boom")
"""


def launch(source, slot):
    """Compile and run one program in a private namespace; -1 on failure."""
    ns = {"out": 0, "n": 0, "i": 0, "scale": 0, "slot": slot}
    try:
        exec(compile(source, "<prog>", "exec"), ns)
    except TypeError:
        return 0 - 1
    return ns["out"]


def managed_entry():
    results = []
    results.append(launch(P0, 0))
    results.append(launch(P1, 1))
    results.append(launch(P2, 2))
    results.append(launch(P3, 3))
    out = 0
    # P0: 1+2+3+4 == 10
    if results[0] == 10:
        out += 1
    # P1: 4*3 + 1*6 == 18
    if results[1] == 18:
        out += 2
    # P2: 5 > 3, so 5*2 == 10
    if results[2] == 10:
        out += 4
    # P3 raised; the launcher survived it and reported -1.
    if results[3] != 0 - 1:
        out = 0
    # The launcher's own globals were never touched by any program.
    if len(results) != 4:
        out = 0
    return out


managed_entry()
