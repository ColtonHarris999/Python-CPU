"""Conditional expressions, chained assignment, `;`, and comprehension
filters, compiled on device (compiler_design.md 5.6 T1/T2/T4).

These four are the grammar this review added; each one was a SyntaxError
from the firmware compiler before. Expected result: 7.

Single-core dicts cannot grow (PY_TRAP_DICT_GROW), so every name the
compiled program STOREs is pre-bound here.
"""

SRC = """\
a = b = 3
c = 1 if a else 2; d = 2 if 0 else 5
e = [x * 2 for x in [1, 2, 3, 4] if x > 2]
f = {k: k + 1 for k in [1, 2] if k > 1}
"""

a = None
b = None
c = None
d = None
e = None
f = None
x = None
k = None


def managed_entry():
    exec(compile(SRC, "<s>", "exec"))
    if a != 3:
        return 0
    if b != 3:
        return 0
    if c != 1:
        return 0
    if d != 5:
        return 0
    # [3, 4] doubled -> [6, 8]
    if len(e) != 2:
        return 0
    if e[0] != 6:
        return 0
    if e[1] != 8:
        return 0
    if f[2] != 3:
        return 0
    return 7


managed_entry()
