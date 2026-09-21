"""T3 parameter + keyword-call round trip (compiler_design.md 5.6 T3).

Exercises everything the def parameter grammar can express on device:
a positional default, ``*args``, keyword-only with a default, ``**kwargs``,
and a CALL_KW site that supplies the keyword-only name out of order.

Defaults ride on the code object (``_bi_code_new`` fields 4 and 6), not on
a function object, so a compiled ``def`` binds them through the CALL FSM
exactly like an image-seeded one. Expected result: 7.

Single-core dicts cannot grow (PY_TRAP_DICT_GROW), so every name the
compiled program STOREs is pre-bound here.
"""

SRC = """\
def f(a, b=2, *rest, c=3, **kw):
    return a + b + len(rest) + c + len(kw)
r0 = f(1)
r1 = f(1, 5, 9, c=0, z=4)
"""

f = None
r0 = None
r1 = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    # f(1)              -> 1 + 2 + 0 + 3 + 0 == 6
    # f(1, 5, 9, c=0, z=4) -> 1 + 5 + 1 + 0 + 1 == 8
    if r0 != 6:
        return 0
    if r1 != 8:
        return 0
    return 7


managed_entry()
